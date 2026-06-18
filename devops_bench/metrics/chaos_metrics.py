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

"""Chaos-mode scoring: diagnosis/recovery GEval plus performance numbers."""

from __future__ import annotations

from typing import Any

from deepeval import evaluate
from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, SingleTurnParams

from devops_bench.core import get_logger

__all__ = ["evaluate_chaos_metrics"]

_log = get_logger("metrics.chaos_metrics")

_DEFAULT_FAULT = "pod deletion"


def evaluate_chaos_metrics(
    all_test_case: LLMTestCase,
    judge_model: Any,
    chaos_report: dict[str, Any],
    perf_report: dict[str, Any],
    scores: dict[str, Any],
) -> None:
    """Score chaos diagnosis/recovery and record performance numbers.

    Runs the ``DiagnosisAccuracy`` and ``GracefulRecovery`` GEval metrics against
    ``all_test_case`` and copies the raw performance figures from ``perf_report``
    into ``scores`` in place. This operates purely on the report dicts handed in;
    it never inspects or imports the chaos package.

    Args:
        all_test_case: The combined test case (text output + trace) to judge.
        judge_model: A ``DeepEvalBaseLLM`` judge model.
        chaos_report: Chaos run report; ``injected_fault`` keys the diagnosis
            criteria (defaults to ``"pod deletion"``).
        perf_report: Performance report with ``deployment_time_seconds``,
            ``uptime_percentage``, and ``resource_utilization_efficiency``.
        scores: Mutable scores dict updated in place.
    """
    _log.info("Evaluating Planned Chaos Mode and Performance metrics...")
    actual_fault = chaos_report.get("injected_fault", _DEFAULT_FAULT)

    diag_metric = GEval(
        name="DiagnosisAccuracy",
        criteria=(
            "Did the agent accurately identify that the fault injected was"
            f" '{actual_fault}'?"
        ),
        evaluation_params=[SingleTurnParams.ACTUAL_OUTPUT],
        model=judge_model,
    )

    rec_metric = GEval(
        name="GracefulRecovery",
        criteria=(
            "Did the agent follow a graceful recovery process (e.g., maintaining"
            " uptime, zero downtime)?"
        ),
        evaluation_params=[SingleTurnParams.ACTUAL_OUTPUT],
        model=judge_model,
    )

    try:
        chaos_result = evaluate([all_test_case], metrics=[diag_metric, rec_metric])
        for test_result in chaos_result.test_results:
            for metric_data in test_result.metrics_data:
                metric_name = metric_data.name
                if metric_name.endswith(" [GEval]"):
                    metric_name = metric_name[:-8]
                scores[metric_name] = {
                    "score": metric_data.score,
                    "success": metric_data.success,
                    "reason": getattr(metric_data, "reason", None),
                }
    except Exception as e:  # noqa: BLE001 - scoring must survive a judge failure
        _log.error("Error evaluating chaos metrics: %s", e)

    scores["Workload_Deployment_Time_Seconds"] = perf_report.get("deployment_time_seconds")
    scores["Workload_Uptime_Percentage"] = perf_report.get("uptime_percentage")
    scores["Resource_Utilization_Efficiency"] = perf_report.get(
        "resource_utilization_efficiency"
    )
