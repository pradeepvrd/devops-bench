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

"""Documentation grounding metrics: constraint GEval scoring and retrieval rate."""

from __future__ import annotations

import json
from typing import Any

from deepeval import evaluate
from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, SingleTurnParams

from devops_bench.core import get_logger

__all__ = ["calculate_doc_retrieval_rate", "evaluate_documentation_grounding"]

_log = get_logger("metrics.grounding")


def calculate_doc_retrieval_rate(
    documentation: list[dict[str, Any]], trajectory: list[Any]
) -> float:
    """Compute the fraction of mapped documentation guides seen in a trajectory.

    A guide counts as accessed when its ``doc_name`` or ``url`` (case-insensitive)
    appears anywhere in the JSON-serialized trajectory steps.

    Args:
        documentation: Mapped guides, each with ``doc_name`` and ``url`` keys.
        trajectory: Agent execution steps (any JSON-serializable objects).

    Returns:
        The accessed fraction in ``[0.0, 1.0]``; ``0.0`` when there is no
        documentation.
    """
    if not documentation:
        return 0.0

    accessed_docs = set()
    for doc in documentation:
        doc_name = doc.get("doc_name") or ""
        doc_name_lower = doc_name.lower()
        url_lower = (doc.get("url") or "").lower()
        found_in_trajectory = False
        for step in trajectory:
            step_str = json.dumps(step).lower()
            # Guard both substrings on truthiness so a missing name/url (now "")
            # does not spuriously match every step (``"" in s`` is always True).
            if (doc_name_lower and doc_name_lower in step_str) or (
                url_lower and url_lower in step_str
            ):
                found_in_trajectory = True
                break
        if found_in_trajectory:
            accessed_docs.add(doc_name)

    return len(accessed_docs) / len(documentation) if len(documentation) > 0 else 0.0


def evaluate_documentation_grounding(
    documentation: list[dict[str, Any]],
    all_test_case: LLMTestCase,
    judge_model: Any,
    scores: dict[str, Any],
) -> None:
    """Score documentation constraints via GEval and derive GroundingAccuracy.

    Each documented constraint becomes a GEval metric evaluated against
    ``all_test_case``. Per-constraint results, an aggregate ``GroundingAccuracy``
    (5.0/2.5/0.0 banded by critical-constraint coverage), and
    ``ParameterRecallAccuracy`` are written into ``scores`` in place.

    Args:
        documentation: Guides, each with a ``constraints`` list of
            ``{"text": str, "critical": bool}`` entries.
        all_test_case: The combined test case (text output + trace) to judge.
        judge_model: A ``DeepEvalBaseLLM`` judge model.
        scores: Mutable scores dict updated in place.
    """
    # Deduplicate constraints by text first so two guides sharing the same
    # constraint produce a single metric; otherwise total > unique and a
    # perfect 5.0 (applied == total) becomes unreachable.
    doc_constraints_map: dict[str, bool] = {}
    for doc in documentation:
        for constraint in doc.get("constraints", []):
            doc_constraints_map[constraint["text"]] = constraint["critical"]

    doc_metrics = [
        GEval(
            name=f"Doc Constraint: {c_text}",
            criteria=(
                "Verify that the actual output fulfills this specific"
                f" documentation constraint/requirement: {c_text}"
            ),
            evaluation_params=[SingleTurnParams.ACTUAL_OUTPUT],
            model=judge_model,
        )
        for c_text in doc_constraints_map
    ]

    if not doc_metrics:
        return

    _log.info(
        "Evaluating %d documentation constraint metrics sequentially...",
        len(doc_metrics),
    )
    for m in doc_metrics:
        try:
            _log.info("Evaluating doc metric: %s...", m.name)
            result = evaluate([all_test_case], metrics=[m])
            for test_result in result.test_results:
                for metric_data in test_result.metrics_data:
                    m_name = metric_data.name
                    if m_name.endswith(" [GEval]"):
                        m_name = m_name[:-8]
                    scores[m_name] = {
                        "score": metric_data.score,
                        "success": metric_data.success,
                        "reason": getattr(metric_data, "reason", None),
                    }
        except Exception as e:  # noqa: BLE001 - one bad metric must not abort scoring
            _log.error("Error evaluating doc metric %s: %s", m.name, e)

    total_constraints = len(doc_metrics)
    applied_constraints = 0
    critical_total = sum(1 for crit in doc_constraints_map.values() if crit)
    critical_applied = 0

    for c_text, c_crit in doc_constraints_map.items():
        m_name = f"Doc Constraint: {c_text}"
        if m_name in scores and scores[m_name]["success"]:
            applied_constraints += 1
            if c_crit:
                critical_applied += 1

    # Score 5.0 (Success), 2.5 (Partial), 0.0 (Failure)
    if total_constraints == 0 or applied_constraints == total_constraints:
        grounding_score = 5.0
    elif applied_constraints == 0:
        grounding_score = 0.0
    elif critical_applied < critical_total:
        grounding_score = 2.5
    else:
        non_critical_total = total_constraints - critical_total
        non_critical_applied = applied_constraints - critical_applied
        if non_critical_total > 0:
            grounding_score = 2.5 + 2.5 * (non_critical_applied / non_critical_total)
        else:
            grounding_score = 5.0

    recall_accuracy = (
        applied_constraints / total_constraints if total_constraints > 0 else 1.0
    )

    scores["GroundingAccuracy"] = {
        "score": grounding_score,
        "success": grounding_score >= 4.0,
        "reason": (
            f"Applied {applied_constraints} out of {total_constraints} documented"
            f" constraints (Critical: {critical_applied}/{critical_total})."
        ),
    }
    scores["ParameterRecallAccuracy"] = recall_accuracy
