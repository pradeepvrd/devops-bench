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

"""Tests for the generate_load fault and its command-execution path."""

from __future__ import annotations

import os
import threading
from types import SimpleNamespace

import pytest

from devops_bench.chaos.base import FAULTS, Fault
from devops_bench.chaos.faults import generate_load
from devops_bench.chaos.faults.generate_load import GenerateLoadFault, run_chaos_command


def test_fault_is_registered():
    assert FAULTS.get("generate_load") is GenerateLoadFault
    assert issubclass(GenerateLoadFault, Fault)


def test_run_chaos_command_splits_argv_and_returns_output(mocker):
    mock_run = mocker.patch.object(
        generate_load,
        "run",
        return_value=SimpleNamespace(stdout="mock stdout", stderr="mock stderr", returncode=0),
    )

    cmd = "~/go/bin/fortio load -qps 100 -t 10s -c 2 http://localhost:8080"
    result = run_chaos_command(cmd)

    fortio = os.path.expanduser("~/go/bin/fortio")
    mock_run.assert_called_once_with(
        [fortio, "load", "-qps", "100", "-t", "10s", "-c", "2", "http://localhost:8080"],
        check=False,
        timeout=40,
    )
    assert "mock stdout" in result
    assert "mock stderr" in result


def test_run_chaos_command_sets_event_on_load_spike(mocker):
    mocker.patch.object(
        generate_load,
        "run",
        return_value=SimpleNamespace(stdout="", stderr="", returncode=0),
    )
    event = threading.Event()

    run_chaos_command("~/go/bin/fortio load -qps 100 http://localhost:8080", event)

    assert event.is_set()


def test_run_chaos_command_does_not_set_event_for_non_load(mocker):
    mocker.patch.object(
        generate_load,
        "run",
        return_value=SimpleNamespace(stdout="", stderr="", returncode=0),
    )
    event = threading.Event()

    run_chaos_command("kubectl get pods", event)

    assert not event.is_set()


def test_run_chaos_command_returns_error_string_on_exception(mocker):
    mocker.patch.object(generate_load, "run", side_effect=RuntimeError("boom"))

    result = run_chaos_command("kubectl get pods")

    assert result.startswith("Error:")
    assert "boom" in result


def test_run_chaos_command_empty_command_guard(mocker):
    mock_run = mocker.patch.object(generate_load, "run")

    for empty in ("", "   ", "\n\t"):
        assert run_chaos_command(empty) == "Error: command string is empty"
    mock_run.assert_not_called()


def test_run_chaos_command_does_not_set_event_on_parse_failure(mocker):
    mock_run = mocker.patch.object(generate_load, "run")
    event = threading.Event()

    # Unbalanced quote: contains the load marker but fails shlex.split, so the
    # command never executes and the event must not be signaled.
    result = run_chaos_command('fortio load "unterminated', event)

    assert result.startswith("Error:")
    assert not event.is_set()
    mock_run.assert_not_called()


def test_inject_rejects_wrong_type():
    fault = GenerateLoadFault()
    with pytest.raises(ValueError):
        fault.inject({"type": "kill_pod"})


def test_goal_uses_spec_target_url():
    fault = GenerateLoadFault()
    spec = {"type": "generate_load", "target": {"service_url": "http://svc:9000"}}

    goal = fault.goal(spec)

    # The spec's service_url drives the prompt instead of a hardcoded constant.
    assert "http://svc:9000" in goal
    assert "localhost:8080" not in goal


def test_goal_falls_back_to_default_url_when_absent():
    fault = GenerateLoadFault()
    goal = fault.goal({"type": "generate_load"})
    assert "http://localhost:8080" in goal


def test_inject_runs_agent_and_signals_event(mocker):
    """Port of the legacy generate_load test: the LLM issues one fortio spike.

    The LLMClient is mocked so no real SDK is touched, and the command path's
    ``run`` is mocked so no real fortio/kubectl executes.
    """
    mock_run = mocker.patch.object(
        generate_load,
        "run",
        return_value=SimpleNamespace(stdout="mock stdout", stderr="mock stderr", returncode=0),
    )

    expected_cmd = "~/go/bin/fortio load -qps 100 -t 10s -c 2 http://localhost:8080"

    # Fake LLM client: first turn asks to run the fortio command, second turn
    # returns the final summary with no further tool calls.
    fake_client = mocker.MagicMock()
    fake_client.format_tools.return_value = "TOOLS"
    fake_client.generate_content = mocker.AsyncMock(side_effect=["resp1", "resp2"])
    fake_client.get_text_content.side_effect = ["", "Disruption complete"]
    fake_client.extract_function_calls.side_effect = [
        [{"name": "run_command", "args": {"command": expected_cmd}, "id": "c1"}],
        [],
    ]
    mocker.patch("devops_bench.chaos.agent.get_model", return_value=fake_client)

    event = threading.Event()
    fault = GenerateLoadFault()
    spec = {
        "type": "generate_load",
        "target": {
            "service_url": "http://localhost:8082",
            "qps": 100,
            "duration": "10s",
            "concurrency": 2,
        },
    }

    report = fault.inject(spec, context={"chaos_active_event": event})

    fortio = os.path.expanduser("~/go/bin/fortio")
    mock_run.assert_called_once_with(
        [fortio, "load", "-qps", "100", "-t", "10s", "-c", "2", "http://localhost:8080"],
        check=False,
        timeout=40,
    )
    assert event.is_set()
    assert report == {"status": "completed", "output": "Disruption complete"}
    assert fault.get_agnostic_spec() == spec
