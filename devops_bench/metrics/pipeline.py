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

"""Batch scoring loop that turns execution results into per-task scores."""

from __future__ import annotations

import importlib
import json
import re
from collections.abc import Iterable
from typing import Any

from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, SingleTurnParams

from devops_bench.core import get_bool, get_logger
from devops_bench.metrics.base import (
    METRICS,
    MetricContext,
    MetricScore,
    run_geval,
)

__all__ = [
    "CHECKLIST_THRESHOLD",
    "ChecklistMetric",
    "evaluate_metrics_batch",
    "extract_checklist_items",
]

_log = get_logger("metrics.pipeline")

# Per-task checklist pass cutoff. The legacy code reused
# ``TOOL_INVOCATION_THRESHOLD`` (0.8) here as a value-coincidence; this constant
# pins the same 0.8 cutoff under its own name so the two concepts are not
# coupled when one of them moves.
CHECKLIST_THRESHOLD = 0.8

# Builtin metric modules whose registrations populate ``METRICS`` on first use
# of :func:`evaluate_metrics_batch`. Importing the metrics package itself stays
# light (CONVENTIONS.md §8); these imports happen at call time so ``deepeval``
# is never pulled by ``import devops_bench.metrics``.
# Order matters: METRICS is a dict, so iteration order = insertion order =
# the order keys land in res["scores"] and thence in results.json. This
# list is pinned to the legacy ordering (outcome -> tool -> checklist ->
# grounding -> chaos) so D3 (results.json shape stability) holds across the
# extraction. pipeline itself is in the list because it carries the
# @METRICS.register("checklist") decorator; re-importing this module while
# it is already in sys.modules is a no-op, the registration ran at first
# import of the module.
_BUILTIN_METRIC_ORDER: tuple[tuple[str, str], ...] = (
    ("devops_bench.metrics.outcome_validity", "outcome_validity"),
    ("devops_bench.metrics.tool_invocation", "tool_invocation"),
    # ``pipeline`` itself registers ``ChecklistMetric`` at module load;
    # re-importing while it is already in ``sys.modules`` is a no-op and the
    # decorator has long since fired.
    ("devops_bench.metrics.pipeline", "checklist"),
    ("devops_bench.metrics.grounding", "grounding"),
    ("devops_bench.metrics.chaos_metrics", "chaos"),
)


def extract_checklist_items(expected_output: str, use_mcp: bool) -> list[str]:
    """Parse per-requirement checklist items from an expected-output string.

    Items are the ``-`` bulleted lines inside the "Critical Requirements" section
    (everything before an "Expected Manifest Generated" marker). When MCP is
    disabled, "expected tool call" requirements are dropped since the agent has
    no tools to invoke.

    Args:
        expected_output: The task's expected-output text.
        use_mcp: Whether the run used MCP tools.

    Returns:
        The cleaned list of requirement strings (bullet markers stripped).
    """
    reqs_section = expected_output
    if "critical requirements:" in reqs_section.lower():
        parts = re.split(r"(?i)critical requirements\s*:", reqs_section, maxsplit=1)
        if len(parts) > 1:
            reqs_section = parts[1]

    if "expected manifest generated:" in reqs_section.lower():
        parts = re.split(
            r"(?i)expected manifest generated\s*:", reqs_section, maxsplit=1
        )
        reqs_section = parts[0]

    # Strip only the leading "- " bullet marker; ``str.strip("- ")`` would also
    # eat trailing hyphens/spaces and corrupt items like "...staging-".
    raw_checklist_items = [
        line.lstrip("- ").strip()
        for line in reqs_section.split("\n")
        if line.strip().startswith("-")
    ]
    checklist_items = []
    for item in raw_checklist_items:
        if not use_mcp and "expected tool call" in item.lower():
            _log.info("Skipping Expected Tool Call criteria: '%s'", item)
            continue
        checklist_items.append(item)
    return checklist_items


@METRICS.register("checklist")
class ChecklistMetric:
    """Registered evaluator scoring per-requirement checklist items.

    For each parsed checklist item the evaluator builds a per-item ``Check: …``
    GEval, scores it, and emits the aggregate ``ChecklistScore`` using
    :data:`CHECKLIST_THRESHOLD` as the pass cutoff.

    Attributes:
        name: Identifier for logging; per-score keys come from each yielded
            :class:`MetricScore`.
    """

    name = "checklist"

    def applies(self, ctx: MetricContext) -> bool:
        """Run only when the result's ``expected_output`` carries bullets."""
        return bool(
            extract_checklist_items(ctx.result.get("expected_output", ""), ctx.use_mcp)
        )

    def evaluate(self, ctx: MetricContext) -> Iterable[MetricScore]:
        """Score each requirement and emit the aggregate ChecklistScore."""
        items = extract_checklist_items(
            ctx.result.get("expected_output", ""), ctx.use_mcp
        )
        dynamic_metrics = [
            GEval(
                name=f"Check: {item}",
                criteria=(
                    "Verify that the actual output fulfills this specific"
                    f" requirement: {item}"
                ),
                evaluation_params=[SingleTurnParams.ACTUAL_OUTPUT],
                model=ctx.judge,
            )
            for item in items
        ]

        out: list[MetricScore] = []
        passed = 0
        total = len(dynamic_metrics)
        for m in dynamic_metrics:
            try:
                _log.info("Evaluating metric: %s...", m.name)
                for ms in run_geval(ctx.all_case, [m]):
                    out.append(ms)
                    if ms.success:
                        passed += 1
            except Exception as e:  # noqa: BLE001 - keep scoring the rest
                _log.error("Error evaluating metric %s: %s", m.name, e)

        ratio = passed / total if total > 0 else 0.0
        out.append(
            MetricScore(
                name="ChecklistScore",
                score=ratio,
                success=ratio >= CHECKLIST_THRESHOLD if total > 0 else False,
                reason=f"Passed {passed} out of {total} checks.",
            )
        )
        return out


def _build_context(
    res: dict[str, Any], judge_model: Any, use_mcp: bool
) -> MetricContext:
    """Build the per-result :class:`MetricContext`, sharing test cases.

    Args:
        res: One execution result dict.
        judge_model: A ``DeepEvalBaseLLM`` judge.
        use_mcp: Whether the run was granted MCP capabilities.

    Returns:
        A populated :class:`MetricContext` with the three test cases built once.
    """
    prompt = res["input"]
    actual_output = res["output"]
    trajectory = res["trajectory"]
    expected_output = res["expected_output"]
    latency = res["latency"]
    retrieval_context = res["retrieval_context"]

    outcome_case = LLMTestCase(
        input=prompt,
        actual_output=actual_output if actual_output else "No response generated",
        expected_output=expected_output,
        retrieval_context=retrieval_context,
        latency=latency,
    )

    combined_actual = {
        "tools_used": res.get("tools", []),
        "execution_trace": trajectory,
    }
    tool_case = LLMTestCase(
        input=prompt,
        actual_output=json.dumps(combined_actual, indent=2),
        expected_output=expected_output,
        latency=latency,
    )

    all_context = {
        "tools_used": res.get("tools", []),
        "execution_trace": trajectory,
        "text_output": actual_output if actual_output else "No response generated",
    }
    all_case = LLMTestCase(
        input=prompt,
        actual_output=json.dumps(all_context, indent=2),
        expected_output=expected_output,
        latency=latency,
    )

    return MetricContext(
        result=res,
        judge=judge_model,
        use_mcp=use_mcp,
        outcome_case=outcome_case,
        tool_case=tool_case,
        all_case=all_case,
    )


def _load_builtin_metric_modules() -> None:
    """Import builtin metric modules so their ``@METRICS.register`` runs.

    The metrics package keeps a lazy ``__getattr__`` facade (CONVENTIONS.md §8),
    so importing ``devops_bench.metrics`` never pulls ``deepeval``. The builtin
    metric modules are imported here, at call time, instead of at package
    import. Already-imported modules are no-ops.
    """
    for module, _ in _BUILTIN_METRIC_ORDER:
        importlib.import_module(module)


def evaluate_metrics_batch(
    detailed_results: list[dict[str, Any]],
    judge_model: Any,
    *,
    use_mcp: bool | None = None,
) -> None:
    """Score a batch of execution results in place via the metrics registry.

    Adding a metric is a new ``@METRICS.register(...)`` class in any metric
    module — there is no orchestration surgery required here. Each registered
    evaluator's :meth:`MetricEvaluator.applies` gates whether it runs for a
    given result, and one failing metric never aborts the rest.

    Args:
        detailed_results: Execution result dicts, each with ``input``,
            ``output``, ``trajectory``, ``expected_output``, ``latency``,
            ``name``, ``retrieval_context``, and optional ``documentation`` /
            ``chaos_spec`` / ``chaos_report`` / ``perf_report`` / ``tools`` keys.
        judge_model: A ``DeepEvalBaseLLM`` judge model.
        use_mcp: Whether the harness granted MCP tool capabilities. ``None``
            falls back to the ``BENCH_USE_MCP`` env var for compatibility while
            CONVENTIONS.md §7's harness-threaded value is wired through.
    """
    _log.info("Starting batch post-processing evaluation metrics...")
    _load_builtin_metric_modules()
    if use_mcp is None:
        use_mcp = get_bool("BENCH_USE_MCP", True)

    builtin_keys = [key for _, key in _BUILTIN_METRIC_ORDER]
    builtin_set = set(builtin_keys)
    # Builtin metrics in the pinned (results.json) order, then any third-party
    # registrations in registry insertion order.
    ordered_keys = builtin_keys + [k for k in METRICS if k not in builtin_set]
    evaluators = [METRICS[k]() for k in ordered_keys]

    for res in detailed_results:
        ctx = _build_context(res, judge_model, use_mcp)
        scores: dict[str, Any] = {}
        _log.info("Evaluating metrics for: %s...", res.get("name"))
        for ev in evaluators:
            try:
                if not ev.applies(ctx):
                    continue
                for ms in ev.evaluate(ctx):
                    scores[ms.name] = ms.to_entry()
            except Exception:  # noqa: BLE001 - one metric must not abort the rest
                _log.exception(
                    "metric %r failed for %s",
                    getattr(ev, "name", ev),
                    res.get("name"),
                )
        res["scores"] = scores
