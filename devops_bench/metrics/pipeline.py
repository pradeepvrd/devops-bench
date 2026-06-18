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

import json
import re
from typing import Any

from deepeval import evaluate
from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, SingleTurnParams

from devops_bench.core import get_bool, get_logger
from devops_bench.metrics.chaos_metrics import evaluate_chaos_metrics
from devops_bench.metrics.grounding import (
    calculate_doc_retrieval_rate,
    evaluate_documentation_grounding,
)
from devops_bench.metrics.outcome_validity import build_outcome_validity_metric
from devops_bench.metrics.tool_invocation import (
    TOOL_INVOCATION_THRESHOLD,
    build_tool_invocation_metric,
)

__all__ = ["extract_checklist_items", "evaluate_metrics_batch"]

_log = get_logger("metrics.pipeline")


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


def _record_metrics(result: Any, scores: dict[str, Any]) -> None:
    """Copy DeepEval metric results into ``scores`` in place.

    A trailing ``" [GEval]"`` suffix (which DeepEval appends to GEval metric
    names) is stripped uniformly so score keys are clean, e.g. ``OutcomeValidity``
    rather than ``OutcomeValidity [GEval]``.

    Args:
        result: A DeepEval evaluation result with ``test_results``.
        scores: Mutable scores dict updated in place.
    """
    for test_result in result.test_results:
        for metric_data in test_result.metrics_data:
            name = metric_data.name
            if name.endswith(" [GEval]"):
                name = name[:-8]
            scores[name] = {
                "score": metric_data.score,
                "success": metric_data.success,
                "reason": getattr(metric_data, "reason", None),
            }


def evaluate_metrics_batch(
    detailed_results: list[dict[str, Any]], judge_model: Any
) -> None:
    """Score a batch of execution results in place.

    For each result this evaluates OutcomeValidity, ToolInvocation (when MCP is
    on), per-requirement checklist metrics, documentation grounding/retrieval,
    and chaos/perf metrics (when a ``chaos_spec`` is present). Scores are written
    to ``res["scores"]``.

    Args:
        detailed_results: Execution result dicts, each with ``input``,
            ``output``, ``trajectory``, ``expected_output``, ``latency``,
            ``name``, ``retrieval_context``, and optional ``documentation`` /
            ``chaos_spec`` / ``chaos_report`` / ``perf_report`` keys.
        judge_model: A ``DeepEvalBaseLLM`` judge model.
    """
    _log.info("Starting batch post-processing evaluation metrics...")
    use_mcp = get_bool("BENCH_USE_MCP", True)

    for res in detailed_results:
        prompt = res["input"]
        actual_output = res["output"]
        trajectory = res["trajectory"]
        expected_output = res["expected_output"]
        latency = res["latency"]
        name = res["name"]
        retrieval_context = res["retrieval_context"]
        documentation = res.get("documentation", [])

        checklist_items = extract_checklist_items(expected_output, use_mcp)
        dynamic_metrics = [
            GEval(
                name=f"Check: {item}",
                criteria=(
                    "Verify that the actual output fulfills this specific"
                    f" requirement: {item}"
                ),
                evaluation_params=[SingleTurnParams.ACTUAL_OUTPUT],
                model=judge_model,
            )
            for item in checklist_items
        ]

        outcome_validity = build_outcome_validity_metric(judge_model)
        tool_invocation = build_tool_invocation_metric(judge_model)

        outcome_test_case = LLMTestCase(
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
        tool_test_case = LLMTestCase(
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
        all_test_case = LLMTestCase(
            input=prompt,
            actual_output=json.dumps(all_context, indent=2),
            expected_output=expected_output,
            latency=latency,
        )

        _log.info("Evaluating metrics for: %s...", name)
        outcome_result = evaluate([outcome_test_case], metrics=[outcome_validity])

        scores: dict[str, Any] = {}
        _record_metrics(outcome_result, scores)

        if use_mcp:
            tool_result = evaluate([tool_test_case], metrics=[tool_invocation])
            _record_metrics(tool_result, scores)

        if dynamic_metrics:
            _log.info(
                "Evaluating %d dynamic metrics sequentially...", len(dynamic_metrics)
            )
            for m in dynamic_metrics:
                try:
                    _log.info("Evaluating metric: %s...", m.name)
                    result = evaluate([all_test_case], metrics=[m])
                    _record_metrics(result, scores)
                except Exception as e:  # noqa: BLE001 - keep scoring the rest
                    _log.error("Error evaluating metric %s: %s", m.name, e)

            passed_checks = sum(
                1
                for m in dynamic_metrics
                if m.name in scores and scores[m.name]["success"]
            )
            total_checks = len(dynamic_metrics)
            scores["ChecklistScore"] = {
                "score": passed_checks / total_checks if total_checks > 0 else 0.0,
                "success": (
                    passed_checks / total_checks >= TOOL_INVOCATION_THRESHOLD
                    if total_checks > 0
                    else False
                ),
                "reason": f"Passed {passed_checks} out of {total_checks} checks.",
            }

        if documentation:
            evaluate_documentation_grounding(
                documentation, all_test_case, judge_model, scores
            )
            scores["DocRetrievalRate"] = calculate_doc_retrieval_rate(
                documentation, trajectory
            )

        if res.get("chaos_spec"):
            evaluate_chaos_metrics(
                all_test_case,
                judge_model,
                res.get("chaos_report", {}),
                res.get("perf_report", {}),
                scores,
            )

        res["scores"] = scores
