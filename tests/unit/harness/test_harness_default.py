# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Tests for the DefaultHarness end-to-end pipeline decomposition."""

from __future__ import annotations

import json

import pytest

from devops_bench.core import ClusterInfo
from devops_bench.harness import default as default_module
from devops_bench.harness.default import DefaultHarness


@pytest.fixture
def harness(monkeypatch):
    """A DefaultHarness with a stub judge and a fixed agent type."""
    monkeypatch.delenv("BENCH_AGENT_TYPE", raising=False)
    monkeypatch.delenv("AGENT_TARGET", raising=False)
    return DefaultHarness(
        project_id="proj-1",
        cluster_name="cluster-1",
        judge_model=object(),
    )


def _agent_result(output="manifest applied"):
    return {
        "output": output,
        "latency": 1.5,
        "tokens": {"in": 1, "out": 2},
        "tools": {"kubectl": 1},
        "trajectory": [{"tool": "kubectl"}],
        "skills": [],
    }


def test_replace_placeholders(harness, monkeypatch):
    monkeypatch.setenv("NAMESPACE", "prod")
    monkeypatch.setenv("TARGET_DEPLOYMENT_NAME", "web")
    out = harness.replace_placeholders(
        "deploy {{CLUSTER_NAME}} in {{PROJECT_ID}}/{{NAMESPACE}} via {{TARGET_DEPLOYMENT_NAME}}",
        "live-cluster",
    )
    assert out == "deploy live-cluster in proj-1/prod via web"


def test_resolve_agent_uses_registry(harness, mocker):
    """resolve_agent imports the module and looks the class up in AGENTS."""
    import_module = mocker.patch.object(default_module.importlib, "import_module")
    agent_instance = mocker.MagicMock()
    agent_cls = mocker.MagicMock(return_value=agent_instance)
    get = mocker.patch.object(default_module.AGENTS, "get", return_value=agent_cls)

    resolved = harness.resolve_agent("cli")

    # cli maps to the gemini CLI module + key, resolved via the registry.
    import_module.assert_called_once_with("devops_bench.agents.cli.gemini")
    get.assert_called_once_with("gemini")
    assert resolved is agent_instance


def test_resolve_agent_unknown_type(harness):
    with pytest.raises(ValueError, match="unknown agent type"):
        harness.resolve_agent("nope")


def test_run_pipeline_happy_path(harness, mocker, tmp_path):
    deployer = mocker.MagicMock()
    deployer.get_cluster_info.return_value = ClusterInfo(name="live-cluster")
    mocker.patch.object(default_module, "get_deployer", return_value=deployer)

    agent = mocker.MagicMock()
    agent.run.return_value = _agent_result()
    mocker.patch.object(harness, "resolve_agent", return_value=agent)

    # No chaos -> no scenario; isolate artifact + scoring side effects.
    mocker.patch.object(default_module, "snapshot_dir", return_value=set())
    collect = mocker.patch.object(
        default_module, "collect_generated_files", return_value=[]
    )
    score = mocker.patch.object(harness, "_score")
    harness.results_root = str(tmp_path)

    item = {
        "name": "Task A",
        "input": "make {{CLUSTER_NAME}} production ready",
        "expected_output": "deployment on {{CLUSTER_NAME}}",
    }
    results = harness.run([item])

    assert len(results) == 1
    res = results[0]
    deployer.up.assert_called_once()
    deployer.down.assert_called_once()
    agent.run.assert_called_once()
    # Placeholders resolved with the deployer-reported cluster name.
    assert res["input"] == "make live-cluster production ready"
    assert res["expected_output"] == "deployment on live-cluster"
    assert res["output"] == "manifest applied"
    assert res["latency"] == 1.5
    collect.assert_called_once()
    score.assert_called_once_with(results)

    # results.json was written under a timestamped run dir.
    run_dirs = list(tmp_path.glob("run_*"))
    assert len(run_dirs) == 1
    saved = json.loads((run_dirs[0] / "results.json").read_text())
    assert saved[0]["name"] == "Task A"


def test_run_with_chaos_starts_scenario_and_drains(harness, mocker, tmp_path):
    deployer = mocker.MagicMock()
    deployer.get_cluster_info.return_value = ClusterInfo(name="live-cluster")
    mocker.patch.object(default_module, "get_deployer", return_value=deployer)

    agent = mocker.MagicMock()
    agent.run.return_value = _agent_result()
    mocker.patch.object(harness, "resolve_agent", return_value=agent)
    mocker.patch.object(default_module, "snapshot_dir", return_value=set())
    mocker.patch.object(default_module, "collect_generated_files", return_value=[])
    mocker.patch.object(harness, "_score")
    harness.results_root = str(tmp_path)

    scenario_manager = mocker.MagicMock()
    scenario_manager.get_reports.return_value = (
        {"status": "success"},
        {"uptime_percentage": 100.0},
    )
    thread = mocker.MagicMock()
    mocker.patch.object(
        harness, "start_scenario", return_value=(scenario_manager, thread)
    )

    item = {
        "name": "Chaos Task",
        "input": "survive the load",
        "expected_output": "stayed up",
        "chaos_spec": [{"action": {"type": "generate_load"}}],
    }
    results = harness.run([item])

    scenario_manager.chaos_active_event.wait.assert_called_once()
    thread.join.assert_called_once()
    # The scenario is always stopped so its port-forward/fortio do not leak.
    scenario_manager.stop.assert_called_once()
    assert results[0]["chaos_report"] == {"status": "success"}
    assert results[0]["perf_report"] == {"uptime_percentage": 100.0}


def test_teardown_skipped_when_no_teardown_env(harness, mocker, monkeypatch):
    monkeypatch.setenv("BENCH_NO_TEARDOWN", "true")
    deployer = mocker.MagicMock()
    harness._teardown(deployer, {"teardown": True}, "Task A")
    deployer.down.assert_not_called()


def test_teardown_skipped_when_config_disables(harness, mocker, monkeypatch):
    monkeypatch.delenv("BENCH_NO_TEARDOWN", raising=False)
    deployer = mocker.MagicMock()
    harness._teardown(deployer, {"teardown": False}, "Task A")
    deployer.down.assert_not_called()


def test_start_scenario_none_without_chaos(harness):
    assert harness.start_scenario(None, None, "cluster-1") is None


def test_start_scenario_builds_daemon_thread(harness, mocker, monkeypatch):
    monkeypatch.setenv("TARGET_DEPLOYMENT_NAME", "frontend")
    monkeypatch.setenv("NAMESPACE", "default")
    sm_instance = mocker.MagicMock()
    sm_cls = mocker.patch.object(
        default_module, "ScenarioManager", return_value=sm_instance
    )
    thread_instance = mocker.MagicMock()
    thread_cls = mocker.patch.object(
        default_module.threading, "Thread", return_value=thread_instance
    )

    chaos_spec = [{"action": {"type": "generate_load"}}]
    result = harness.start_scenario(chaos_spec, None, "live-cluster")

    assert result == (sm_instance, thread_instance)
    sm_cls.assert_called_once_with("frontend", "default")
    # The scenario runs on a daemon thread.
    assert thread_instance.daemon is True
    thread_instance.start.assert_called_once()
    # The first chaos spec is handed to the manager.
    _, kwargs = thread_cls.call_args
    assert kwargs["args"][0] == chaos_spec[0]


def test_shared_defaults_consistent_when_env_unset(harness, mocker, monkeypatch):
    """Prompt placeholder + chaos target use the same default deployment/ns."""
    monkeypatch.delenv("TARGET_DEPLOYMENT_NAME", raising=False)
    monkeypatch.delenv("NAMESPACE", raising=False)

    # The placeholder path resolves to the shared defaults.
    prompt = harness.replace_placeholders(
        "{{TARGET_DEPLOYMENT_NAME}}/{{NAMESPACE}}", "c"
    )
    assert prompt == f"{default_module._DEFAULT_TARGET_DEPLOYMENT}/{default_module._DEFAULT_NAMESPACE}"

    # The scenario path constructs ScenarioManager with the same pair.
    sm = mocker.patch.object(default_module, "ScenarioManager")
    mocker.patch.object(default_module.threading, "Thread")
    harness.start_scenario([{"action": {"type": "generate_load"}}], None, "c")
    sm.assert_called_once_with(
        default_module._DEFAULT_TARGET_DEPLOYMENT, default_module._DEFAULT_NAMESPACE
    )


def test_run_stops_scenario_on_exception(harness, mocker, tmp_path):
    """A mid-task failure still stops the scenario so resources do not leak."""
    deployer = mocker.MagicMock()
    deployer.get_cluster_info.return_value = ClusterInfo(name="live-cluster")
    mocker.patch.object(default_module, "get_deployer", return_value=deployer)

    agent = mocker.MagicMock()
    agent.run.side_effect = RuntimeError("agent blew up")
    mocker.patch.object(harness, "resolve_agent", return_value=agent)
    mocker.patch.object(default_module, "snapshot_dir", return_value=set())
    mocker.patch.object(harness, "_score")
    harness.results_root = str(tmp_path)

    scenario_manager = mocker.MagicMock()
    thread = mocker.MagicMock()
    mocker.patch.object(
        harness, "start_scenario", return_value=(scenario_manager, thread)
    )

    item = {
        "name": "Doomed Task",
        "input": "do the thing",
        "expected_output": "done",
        "chaos_spec": [{"action": {"type": "generate_load"}}],
    }
    harness.run([item])

    # Scenario cleanup + teardown ran despite the exception.
    scenario_manager.stop.assert_called_once()
    deployer.down.assert_called_once()


def test_score_builds_judge_when_absent(mocker):
    harness = DefaultHarness("p", "c", judge_model=None)
    judge = object()
    get_judge = mocker.patch(
        "devops_bench.metrics.get_judge_model", return_value=judge
    )
    evaluate = mocker.patch("devops_bench.metrics.evaluate_metrics_batch")

    results = [{"name": "x"}]
    harness._score(results)

    get_judge.assert_called_once_with()
    evaluate.assert_called_once_with(results, judge)
