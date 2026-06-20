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

"""Tests for GenerateLoadFault — inject path, command runner, system prompt."""

from __future__ import annotations

import threading
from subprocess import CompletedProcess
from unittest.mock import patch

from devops_bench.chaos.base import ChaosResult
from devops_bench.chaos.faults import generate_load as gl
from devops_bench.chaos.faults.generate_load import (
    GenerateLoadFault,
    LoadTarget,
    build_system_instruction,
    run_chaos_command,
)
from devops_bench.core.context import RunContext


def _make_ctx() -> RunContext:
    return RunContext(task_id="test")


def test_build_system_instruction_embeds_target_url():
    msg = build_system_instruction("http://localhost:9999")
    assert "http://localhost:9999" in msg
    assert "fortio" in msg


def test_run_chaos_command_rejects_empty_command():
    assert run_chaos_command("   ") == "Error: command string is empty"


def test_run_chaos_command_sets_event_only_on_load_marker():
    event = threading.Event()
    fake = CompletedProcess(args=["fortio"], returncode=0, stdout="OUT", stderr="ERR")
    with patch.object(gl, "run", return_value=fake) as run_mock:
        out = run_chaos_command("fortio load -qps 50 http://x", chaos_active_event=event)

    assert event.is_set()
    assert "Stdout:\nOUT" in out
    assert "Stderr:\nERR" in out
    # shlex-split argv reached the executor, not a shell string.
    argv = run_mock.call_args.args[0]
    assert argv[0] == "fortio"
    assert argv[1:3] == ["load", "-qps"]


def test_run_chaos_command_does_not_set_event_for_unrelated_command():
    event = threading.Event()
    fake = CompletedProcess(args=["kubectl"], returncode=0, stdout="x", stderr="")
    with patch.object(gl, "run", return_value=fake):
        run_chaos_command("kubectl get pods", chaos_active_event=event)
    assert not event.is_set()


def test_run_chaos_command_surfaces_executor_exception_as_error_string():
    with patch.object(gl, "run", side_effect=RuntimeError("boom")):
        out = run_chaos_command("fortio load http://x")
    assert out.startswith("Error: ")
    assert "boom" in out


def test_inject_returns_chaos_result_on_success():
    fault = GenerateLoadFault(
        target=LoadTarget(service_url="http://localhost:8080", qps=50)
    )

    # Patch the ChaosAgent the fault constructs so no model / SDK / network runs.
    class _StubAgent:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

        def run(self, goal: str) -> str:
            assert "http://localhost:8080" in goal  # goal carries the rewritten URL
            return "spike complete"

    # ``ChaosAgent`` is imported lazily inside ``inject`` (Phase 4 keeps the
    # agent + models chain out of sys.modules until injection runs), so the
    # patch must target the source module rather than the fault module.
    with patch("devops_bench.chaos.agent.ChaosAgent", _StubAgent):
        result = fault.inject(_make_ctx())

    assert isinstance(result, ChaosResult)
    assert result.success is True
    assert result.injected_fault == "generate_load"
    assert result.output == "spike complete"
    assert result.elapsed_time >= 0.0
    assert result.error is None


def test_inject_converts_agent_failure_to_failed_chaos_result():
    fault = GenerateLoadFault(target=LoadTarget(service_url="http://x", qps=1))

    class _BoomAgent:
        def __init__(self, **kwargs):
            pass

        def run(self, goal: str) -> str:
            raise RuntimeError("model offline")

    with patch("devops_bench.chaos.agent.ChaosAgent", _BoomAgent):
        result = fault.inject(_make_ctx())

    assert result.success is False
    assert result.injected_fault == "generate_load"
    assert result.error is not None
    assert "model offline" in result.error


def test_inject_threads_chaos_active_event_through_to_agent():
    fault = GenerateLoadFault(target=LoadTarget(service_url="http://x", qps=1))
    event = threading.Event()

    captured: dict = {}

    class _CapturingAgent:
        def __init__(self, **kwargs):
            captured.update(kwargs)

        def run(self, goal: str) -> str:
            return "ok"

    with patch("devops_bench.chaos.agent.ChaosAgent", _CapturingAgent):
        fault.inject(_make_ctx(), chaos_active_event=event)

    assert captured["chaos_active_event"] is event
    assert captured["tool"] is gl.RUN_COMMAND_TOOL
    assert captured["tool_handler"] is gl.run_chaos_command
    # The system instruction targets the rewritten URL from the spec.
    assert "http://x" in captured["system_instruction"]


def test_goal_dumps_spec_with_target_url():
    fault = GenerateLoadFault(target=LoadTarget(service_url="http://svc", qps=42))
    goal = fault.goal()
    assert "generate_load" in goal
    assert "http://svc" in goal
    assert "42" in goal
