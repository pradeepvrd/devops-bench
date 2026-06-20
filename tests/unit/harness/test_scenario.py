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

"""Scenario wiring tests (CONVENTIONS.md §4.2 / harness handoff §9.1/§9.2).

The scenario manager runs the typed chaos seam (``trigger.wait`` then
``action.inject``) and resolves the chaos ``verify`` key against a
**mapping** (not a list scan) supplied by the orchestrator. Fakes stand in
for both seams so the test exercises only the wiring — never a real cluster
or a real LLM.
"""

from __future__ import annotations

import threading
from typing import Any
from unittest.mock import patch

import pytest

from devops_bench.chaos import ChaosResult, ChaosSpec
from devops_bench.chaos.faults.generate_load import GenerateLoadFault
from devops_bench.chaos.triggers.time_delay import TimeTrigger
from devops_bench.core.context import RunContext
from devops_bench.harness.scenario import ScenarioManager
from devops_bench.verification import VerificationResult, VerifierAgent


def _build_spec(*, verify_key: str | None) -> ChaosSpec:
    """Build a typed :class:`ChaosSpec` mirroring the optimize-scale entry."""
    return ChaosSpec.model_validate(
        {
            "name": "Test Disruption",
            "trigger": {"type": "time", "delay_seconds": 0},
            "action": {
                "type": "generate_load",
                "target": {
                    "service_url": "http://example.svc.cluster.local",
                    "qps": 50,
                },
            },
            "verify": verify_key,
        }
    )


def _build_ctx() -> RunContext:
    return RunContext(task_id="t", task_name="t")


def test_scenario_drives_trigger_wait_then_action_inject() -> None:
    """The seam: trigger.wait runs first, then action.inject — no inline goal builder."""
    spec = _build_spec(verify_key=None)
    order: list[str] = []

    def fake_wait(self: TimeTrigger, ctx: RunContext) -> None:
        order.append("trigger.wait")

    def fake_inject(
        self: GenerateLoadFault,
        ctx: RunContext,
        event: threading.Event | None,
    ) -> ChaosResult:
        order.append("action.inject")
        if event is not None:
            event.set()
        return ChaosResult(
            success=True,
            injected_fault=self.type,
            output="ok",
            elapsed_time=0.1,
        )

    with (
        patch.object(TimeTrigger, "wait", fake_wait),
        patch.object(GenerateLoadFault, "inject", fake_inject),
    ):
        manager = ScenarioManager(
            target_deployment="dep",
            namespace="ns",
            verification_mapping={},
            skip_port_forward=True,
        )
        manager.run_chaos_and_verification(spec, _build_ctx())

    assert order == ["trigger.wait", "action.inject"]
    chaos_report, perf_report = manager.get_reports()
    assert chaos_report["status"] == "success"
    assert chaos_report["injected_fault"] == "generate_load"
    assert chaos_report["name"] == "Test Disruption"
    # No verification mapping resolution happened (verify_key was None).
    assert "verification" not in chaos_report
    assert perf_report == {}


def test_scenario_rewrites_action_url_to_local_port_forward() -> None:
    """``action.inject`` sees ``http://localhost:8080``, not the in-cluster URL."""
    spec = _build_spec(verify_key=None)
    captured: dict[str, Any] = {}

    def fake_inject(self: GenerateLoadFault, ctx, event):
        captured["service_url"] = self.target.service_url
        return ChaosResult(success=True, injected_fault=self.type, elapsed_time=0.0)

    with (
        patch.object(TimeTrigger, "wait", lambda self, ctx: None),
        patch.object(GenerateLoadFault, "inject", fake_inject),
    ):
        manager = ScenarioManager(
            target_deployment="dep",
            namespace="ns",
            skip_port_forward=True,
        )
        manager.run_chaos_and_verification(spec, _build_ctx())

    assert captured["service_url"] == "http://localhost:8080"


def test_scenario_resolves_verify_against_mapping() -> None:
    """The chaos ``verify`` key is looked up in the harness-supplied mapping."""
    spec = _build_spec(verify_key="planned-verify")
    verification_node = object()  # opaque stand-in; VerifierAgent is mocked

    fake_result = VerificationResult(
        success=True, elapsed_time=2.5, reason="all good"
    )

    with (
        patch.object(TimeTrigger, "wait", lambda self, ctx: None),
        patch.object(
            GenerateLoadFault,
            "inject",
            lambda self, ctx, event: ChaosResult(
                success=True, injected_fault=self.type, elapsed_time=0.0
            ),
        ),
        patch.object(
            VerifierAgent, "wait_for_condition", return_value=fake_result
        ) as mock_wait,
    ):
        manager = ScenarioManager(
            target_deployment="dep",
            namespace="ns",
            verification_mapping={"planned-verify": verification_node},
            skip_port_forward=True,
        )
        manager.run_chaos_and_verification(spec, _build_ctx())

    # The mapping value (not a list-scanned dict) flowed straight to the
    # VerifierAgent — the lookup is O(1) and never imports verification on the
    # chaos side.
    mock_wait.assert_called_once_with(verification_node, timeout_sec=120)

    chaos_report, perf_report = manager.get_reports()
    assert chaos_report["verification"]["success"] is True
    assert chaos_report["verification"]["reason"] == "all good"
    # Perf report is derived from the typed VerificationResult.
    assert perf_report == {
        "deployment_time_seconds": 2.5,
        "uptime_percentage": 100.0,
        "resource_utilization_efficiency": 1.0,
    }


def test_scenario_unknown_verify_key_logs_and_skips() -> None:
    """An unmapped ``verify:`` key is logged + skipped, never silent-dropped."""
    spec = _build_spec(verify_key="not-in-mapping")

    with (
        patch.object(TimeTrigger, "wait", lambda self, ctx: None),
        patch.object(
            GenerateLoadFault,
            "inject",
            lambda self, ctx, event: ChaosResult(
                success=True, injected_fault=self.type, elapsed_time=0.0
            ),
        ),
        patch.object(VerifierAgent, "wait_for_condition") as mock_wait,
    ):
        manager = ScenarioManager(
            target_deployment="dep",
            namespace="ns",
            verification_mapping={"some-other-key": object()},
            skip_port_forward=True,
        )
        manager.run_chaos_and_verification(spec, _build_ctx())

    # Never called — the unknown key was logged + skipped.
    mock_wait.assert_not_called()
    chaos_report, _ = manager.get_reports()
    assert chaos_report["status"] == "success"
    assert "verification" not in chaos_report


def test_chaos_failure_lands_typed_error_into_report() -> None:
    """A ``ChaosResult(success=False, error=...)`` flows into the chaos report."""
    spec = _build_spec(verify_key=None)

    def failing_inject(self, ctx, event):
        return ChaosResult(
            success=False,
            injected_fault=self.type,
            elapsed_time=0.0,
            error="fortio not found",
        )

    with (
        patch.object(TimeTrigger, "wait", lambda self, ctx: None),
        patch.object(GenerateLoadFault, "inject", failing_inject),
    ):
        manager = ScenarioManager(
            target_deployment="dep",
            namespace="ns",
            skip_port_forward=True,
        )
        manager.run_chaos_and_verification(spec, _build_ctx())

    chaos_report, _ = manager.get_reports()
    assert chaos_report["status"] == "failed"
    assert chaos_report["error"] == "fortio not found"


def test_stop_releases_port_forward_and_aborts_verification() -> None:
    """``stop()`` is exception-safe and sets the abort flag once."""
    manager = ScenarioManager(
        target_deployment="dep",
        namespace="ns",
        skip_port_forward=True,
    )
    manager.stop()  # No port-forward process; just sets the abort event.
    assert manager._aborted.is_set()  # noqa: SLF001
    # Idempotent — the second call must not raise.
    manager.stop()


@pytest.fixture(autouse=True)
def _no_real_kubectl(monkeypatch: pytest.MonkeyPatch) -> None:
    """Guard against this file accidentally shelling out to ``kubectl``.

    Every test sets ``skip_port_forward=True``, but the guard pins the
    invariant explicitly so a future refactor that forgets the flag fails
    loudly instead of attempting a real port-forward.
    """

    def _boom(*args, **kwargs):  # pragma: no cover - exercised only on regression
        raise RuntimeError("test attempted to spawn a real kubectl process")

    monkeypatch.setattr("devops_bench.harness.scenario.subprocess.Popen", _boom)
