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

"""Targeted unit tests for ``DefaultHarness`` internals not covered elsewhere.

Tests in this file exercise the harness-level wiring beyond the agent /
scenario / metrics seams (those have their own files): the scenario-drain
timed-out path, the constructor-arg-driven deployment / namespace defaults,
the cached granted-skill-paths snapshot, and the narrowed builtin-agent
import behavior.
"""

from __future__ import annotations

import importlib
import threading
from typing import Any

import pytest

from devops_bench.core import MissingDependencyError
from devops_bench.harness import default as harness_default
from devops_bench.harness.default import DefaultHarness


@pytest.fixture
def isolated_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """Strip BENCH_* / AGENT_* env so the harness reads predictable defaults."""
    for var in (
        "BENCH_USE_MCP",
        "BENCH_AGENT_TYPE",
        "AGENT_MCP_SERVER",
        "AGENT_ALLOWED_TOOLS",
        "AGENT_SKILLS_PATHS",
        "AGENT_RULES_TEXT",
        "AGENT_TARGET",
        "AGENT_MODEL",
        "AGENT_PROVIDER",
        "TARGET_DEPLOYMENT_NAME",
        "NAMESPACE",
    ):
        monkeypatch.delenv(var, raising=False)


def test_drain_scenario_stamps_timed_out_when_thread_still_alive(
    isolated_env: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A scenario thread that outlives the join budget is flagged on the report."""
    harness = DefaultHarness(project_id="p", cluster_name="c")

    # Drive the join budget to ~0 so the thread is "still alive" on return
    # without sleeping in the test. The harness reads the module global at
    # call time, so patching the attribute on the module flexes the path.
    monkeypatch.setattr(harness_default, "_SCENARIO_JOIN_SEC", 0.01)

    class _StuckScenario:
        """Stand-in scenario manager whose reports stay partial."""

        def get_reports(self) -> tuple[dict[str, Any], dict[str, Any]]:
            return ({"status": "initiated", "injected_fault": "x"}, {})

    stop_event = threading.Event()

    def _hang() -> None:
        # Hold the thread alive past the join budget so ``is_alive`` is True
        # on return; the event lets the test release the thread on cleanup.
        stop_event.wait(timeout=2.0)

    scenario_thread = threading.Thread(target=_hang, daemon=True)
    scenario_thread.start()
    try:
        chaos_report, perf_report = harness._drain_scenario(  # noqa: SLF001
            _StuckScenario(), scenario_thread
        )
        assert chaos_report["status"] == "timed_out"
        # Partial fields from the underlying scenario carry through so the
        # operator sees how far it got before the cutoff.
        assert chaos_report["injected_fault"] == "x"
        assert perf_report == {}
    finally:
        stop_event.set()
        scenario_thread.join(timeout=2.0)


def test_drain_scenario_returns_empty_when_no_scenario_scheduled(
    isolated_env: None,
) -> None:
    """No chaos for the task → both reports are empty dicts (legacy contract)."""
    harness = DefaultHarness(project_id="p", cluster_name="c")
    chaos_report, perf_report = harness._drain_scenario(None, None)  # noqa: SLF001
    assert chaos_report == {} and perf_report == {}


def test_default_target_deployment_and_namespace_are_ctor_args(
    isolated_env: None,
) -> None:
    """A non-Hypercompute embedder can override the legacy defaults at ctor.

    No env vars set; the harness's overrides flow through to
    ``replace_placeholders`` so a task with
    ``{{TARGET_DEPLOYMENT_NAME}}``/``{{NAMESPACE}}`` resolves to the
    embedder's values rather than the legacy literals.
    """
    harness = DefaultHarness(
        project_id="p",
        cluster_name="c",
        default_target_deployment="my-app",
        default_namespace="custom-ns",
    )
    resolved = harness.replace_placeholders(
        "deploy={{TARGET_DEPLOYMENT_NAME}} ns={{NAMESPACE}}",
        cluster_name="cl",
    )
    assert resolved == "deploy=my-app ns=custom-ns"


def test_granted_skill_paths_snapshot_captured_once(
    isolated_env: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``_granted_skill_paths`` snapshots once at __init__, not per record.

    Removes the env-drift surface: a mid-run change to
    ``AGENT_SKILLS_PATHS`` must NOT show up in record records, because
    the harness is the single source of truth for what was granted.
    """
    monkeypatch.setenv("AGENT_SKILLS_PATHS", "/skills/a,/skills/b")
    harness = DefaultHarness(project_id="p", cluster_name="c")
    assert harness._granted_skill_paths == ("/skills/a", "/skills/b")  # noqa: SLF001

    # A later env mutation must not move the snapshot — the captured
    # tuple is the authority for the rest of the run.
    monkeypatch.setenv("AGENT_SKILLS_PATHS", "/skills/x")
    assert harness._granted_skill_paths == ("/skills/a", "/skills/b")  # noqa: SLF001


def test_ensure_builtin_agents_swallows_only_import_errors(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Optional-SDK absence is swallowed; real bugs re-raise.

    ``ImportError`` / ``MissingDependencyError`` are the narrow-catch
    classes — anything else (``SyntaxError``, ``RuntimeError`` at module
    top, etc.) must bubble out so the operator sees the real failure
    instead of a silent ``debug`` log.
    """
    # Case 1: ImportError is swallowed — function returns normally.
    def fake_import_missing_sdk(name: str) -> Any:
        raise ImportError("anthropic SDK not installed")

    monkeypatch.setattr(importlib, "import_module", fake_import_missing_sdk)
    harness_default._ensure_builtin_agents_registered()  # noqa: SLF001

    # Case 2: a non-import bug must NOT be silently swallowed.
    def fake_import_buggy_module(name: str) -> Any:
        raise SyntaxError("agent module is broken")

    monkeypatch.setattr(importlib, "import_module", fake_import_buggy_module)
    with pytest.raises(SyntaxError):
        harness_default._ensure_builtin_agents_registered()  # noqa: SLF001

    # Case 3: MissingDependencyError is also swallowed (its semantic class).
    def fake_missing_dep(name: str) -> Any:
        raise MissingDependencyError("optional-feature", "extras-marker")

    monkeypatch.setattr(importlib, "import_module", fake_missing_dep)
    harness_default._ensure_builtin_agents_registered()  # noqa: SLF001
