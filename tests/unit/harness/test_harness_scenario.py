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

"""Tests for the ScenarioManager chaos + verification orchestration."""

from __future__ import annotations

import pytest

from devops_bench.harness import scenario as scenario_module
from devops_bench.harness.scenario import ScenarioManager
from devops_bench.verification import VerificationResult


@pytest.fixture
def manager(mocker):
    """A ScenarioManager with its chaos/verifier agents stubbed out at init."""
    mocker.patch.object(scenario_module, "ChaosAgent")
    mocker.patch.object(scenario_module, "VerifierAgent")
    return ScenarioManager("my-deployment", "my-namespace")


def test_run_chaos_and_verification_success(manager, mocker):
    inject = mocker.patch.object(ScenarioManager, "_inject_chaos_with_delay")
    spec = {
        "name": "Test Planned load",
        "trigger": {"type": "time", "delay_seconds": 0},
        "action": {
            "type": "generate_load",
            "target": {"service_url": "http://my-service", "qps": 100},
        },
        "verification": {"pod_spec": {"type": "pod_healthy", "selector": "app=my-app"}},
    }
    verification_result = VerificationResult(
        success=True, elapsed_time=12.5, reason="pod_spec succeeded", details={}
    )
    manager.verifier_agent.wait_for_condition = mocker.MagicMock(
        return_value=verification_result
    )

    manager.run_chaos_and_verification(spec)

    inject.assert_called_once_with(spec["trigger"], spec["action"])
    manager.verifier_agent.wait_for_condition.assert_called_once_with(
        spec["verification"], timeout_sec=120
    )

    chaos_report, perf_report = manager.get_reports()
    assert chaos_report["status"] == "success"
    assert chaos_report["verification"] == verification_result.model_dump()
    assert perf_report["deployment_time_seconds"] == 12.5
    assert perf_report["uptime_percentage"] == 100.0
    assert perf_report["resource_utilization_efficiency"] == 1.0


def test_run_chaos_and_verification_failure(manager, mocker):
    inject = mocker.patch.object(ScenarioManager, "_inject_chaos_with_delay")
    spec = {
        "name": "Test Planned load",
        "trigger": {"type": "time", "delay_seconds": 0},
        "action": {
            "type": "generate_load",
            "target": {"service_url": "http://my-service", "qps": 100},
        },
        "verification": {"pod_spec": {"type": "pod_healthy", "selector": "app=my-app"}},
    }
    verification_result = VerificationResult(
        success=False, elapsed_time=120.0, reason="pod_spec failed", details={}
    )
    manager.verifier_agent.wait_for_condition = mocker.MagicMock(
        return_value=verification_result
    )

    manager.run_chaos_and_verification(spec)

    inject.assert_called_once_with(spec["trigger"], spec["action"])
    manager.verifier_agent.wait_for_condition.assert_called_once_with(
        spec["verification"], timeout_sec=120
    )

    chaos_report, perf_report = manager.get_reports()
    assert chaos_report["status"] == "success"
    assert chaos_report["verification"] == verification_result.model_dump()
    assert perf_report["deployment_time_seconds"] is None
    assert perf_report["uptime_percentage"] == 0.0
    assert perf_report["resource_utilization_efficiency"] == 0.0


def test_run_chaos_and_verification_decoupled_spec(manager, mocker):
    inject = mocker.patch.object(ScenarioManager, "_inject_chaos_with_delay")
    spec = {
        "name": "Test Planned load",
        "trigger": {"type": "time", "delay_seconds": 0},
        "action": {
            "type": "generate_load",
            "target": {"service_url": "http://my-service", "qps": 100},
        },
        "verification": "My Decoupled Verification",
    }
    verification_specs = [
        {
            "name": "My Decoupled Verification",
            "pod_spec": {"type": "pod_healthy", "selector": "app=my-app"},
        }
    ]
    verification_result = VerificationResult(
        success=True,
        elapsed_time=15.0,
        reason="decoupled pod_spec succeeded",
        details={},
    )
    manager.verifier_agent.wait_for_condition = mocker.MagicMock(
        return_value=verification_result
    )

    manager.run_chaos_and_verification(spec, verification_specs)

    inject.assert_called_once_with(spec["trigger"], spec["action"])
    manager.verifier_agent.wait_for_condition.assert_called_once_with(
        verification_specs[0], timeout_sec=120
    )

    chaos_report, perf_report = manager.get_reports()
    assert chaos_report["status"] == "success"
    assert chaos_report["verification"] == verification_result.model_dump()
    assert perf_report["deployment_time_seconds"] == 15.0
    assert perf_report["uptime_percentage"] == 100.0
    assert perf_report["resource_utilization_efficiency"] == 1.0


def test_inject_failure_marks_report_failed(manager, mocker):
    mocker.patch.object(
        ScenarioManager,
        "_inject_chaos_with_delay",
        side_effect=RuntimeError("boom"),
    )
    spec = {
        "name": "Test Planned load",
        "trigger": {"delay_seconds": 0},
        "action": {"type": "generate_load"},
        "verification": {"pod_spec": {"type": "pod_healthy", "selector": "app=x"}},
    }
    manager.verifier_agent.wait_for_condition = mocker.MagicMock()

    manager.run_chaos_and_verification(spec)

    chaos_report, perf_report = manager.get_reports()
    assert chaos_report["status"] == "failed"
    assert chaos_report["error"] == "boom"
    # Verification is skipped when injection fails.
    manager.verifier_agent.wait_for_condition.assert_not_called()
    assert perf_report == {}


def test_inject_chaos_opens_and_terminates_port_forward(manager, mocker):
    """_inject_chaos_with_delay opens kubectl port-forward and tears it down."""
    pf_process = mocker.MagicMock()
    popen = mocker.patch.object(
        scenario_module.subprocess, "Popen", return_value=pf_process
    )
    mocker.patch.object(scenario_module.time, "sleep")

    action = {"type": "generate_load", "target": {"service_url": "http://svc"}}
    manager._inject_chaos_with_delay({"delay_seconds": 0}, action)

    # Port-forward is opened against the target deployment...
    popen.assert_called_once()
    pf_argv = popen.call_args.args[0]
    assert pf_argv[:2] == ["kubectl", "port-forward"]
    assert "deployment/my-deployment" in pf_argv
    assert "8080:8080" in pf_argv

    # ...with stdout/stderr discarded so an unread pipe cannot deadlock kubectl.
    assert popen.call_args.kwargs["stdout"] == scenario_module.subprocess.DEVNULL
    assert popen.call_args.kwargs["stderr"] == scenario_module.subprocess.DEVNULL

    # ...the chaos agent is driven against the local URL...
    manager.chaos_agent.run.assert_called_once()
    goal = manager.chaos_agent.run.call_args.args[0]
    assert "http://localhost:8080" in goal

    # ...and the port-forward is always terminated.
    pf_process.terminate.assert_called_once()
    pf_process.wait.assert_called_once()


def test_stop_aborts_and_terminates_port_forward(manager, mocker):
    """stop() sets the abort flag and terminates a live port-forward."""
    pf_process = mocker.MagicMock()
    pf_process.poll.return_value = None  # still running
    manager.pf_process = pf_process

    manager.stop()

    assert manager._aborted.is_set()
    pf_process.terminate.assert_called_once()


def test_stop_skips_verification(manager, mocker):
    """A scenario stopped before verification does not run the verifier."""
    mocker.patch.object(ScenarioManager, "_inject_chaos_with_delay")
    manager.verifier_agent.wait_for_condition = mocker.MagicMock()
    manager.stop()  # abort before the scenario body runs

    spec = {
        "name": "Test",
        "trigger": {"delay_seconds": 0},
        "action": {"type": "generate_load"},
        "verification": {"pod_spec": {"type": "pod_healthy", "selector": "app=x"}},
    }
    manager.run_chaos_and_verification(spec)

    manager.verifier_agent.wait_for_condition.assert_not_called()


def test_stop_is_safe_when_no_process(manager):
    """stop() is a no-op-safe when no port-forward was ever opened."""
    manager.pf_process = None
    manager.stop()  # must not raise
    assert manager._aborted.is_set()
