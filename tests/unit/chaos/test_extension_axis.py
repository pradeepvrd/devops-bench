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

"""Extension-axis acceptance: a dummy fault/trigger resolves via the registry.

CONVENTIONS §9 ("Extension-axis tests"): the harness-resolution path is the
:data:`FAULTS` / :data:`TRIGGERS` registries — dropping a new concrete in and
decorating it must surface through ``REGISTRY.get(key)`` with no edit anywhere
else. This test pins that for chaos.

Phase A — the registry is consumed by the harness for resolution; ``ChaosSpec``
*parsing* still requires a Union edit until chaos Phase 4 swaps to
registry-driven parsing (CONVENTIONS §4 "Phase-A → Phase-4 swap"). Once that
lands, this same dummy will additionally parse through ``ChaosSpec`` with no
spec edit.
"""

from __future__ import annotations

import threading
from typing import Literal

import pytest

from devops_bench.chaos.base import FAULTS, TRIGGERS, ChaosResult, Fault, Trigger
from devops_bench.core.context import RunContext


@pytest.fixture
def _isolated_registries():
    """Register dummies for one test and rip them out afterwards."""
    saved_faults = dict(FAULTS.items())
    saved_triggers = dict(TRIGGERS.items())
    try:
        yield
    finally:
        # Restore the registries to their pre-test state so other tests cannot
        # see the dummy keys; ``Registry`` is mutable and module-scoped.
        for key in list(FAULTS.keys()):
            if key not in saved_faults:
                del FAULTS._items[key]  # type: ignore[attr-defined]
        for key in list(TRIGGERS.keys()):
            if key not in saved_triggers:
                del TRIGGERS._items[key]  # type: ignore[attr-defined]


def test_dummy_fault_resolves_via_registry_with_no_central_edit(_isolated_registries):
    @FAULTS.register("dummy")
    class _DummyFault(Fault):
        type: Literal["dummy"] = "dummy"

        def inject(
            self,
            ctx: RunContext,
            chaos_active_event: threading.Event | None = None,
        ) -> ChaosResult:
            return ChaosResult(success=True, injected_fault=self.type, output="dummy")

    # Harness-resolution path: registry.get(key) — no edit to chaos/spec.py
    # required for the harness to find a brand-new fault.
    assert "dummy" in FAULTS
    cls = FAULTS.get("dummy")
    assert cls is _DummyFault
    res = _DummyFault().inject(RunContext(task_id="t"))
    assert res.success is True
    assert res.injected_fault == "dummy"


def test_dummy_trigger_resolves_via_registry_with_no_central_edit(_isolated_registries):
    @TRIGGERS.register("dummy")
    class _DummyTrigger(Trigger):
        type: Literal["dummy"] = "dummy"

        def wait(self, ctx: RunContext) -> None:
            return None

    assert "dummy" in TRIGGERS
    cls = TRIGGERS.get("dummy")
    assert cls is _DummyTrigger
    _DummyTrigger().wait(RunContext(task_id="t"))  # smoke: no crash
