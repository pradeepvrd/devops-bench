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

"""Tests for the batch scoring pipeline and checklist parsing."""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import MagicMock

from devops_bench.metrics import pipeline
from devops_bench.metrics.pipeline import evaluate_metrics_batch, extract_checklist_items

# --- extract_checklist_items (pure logic) -------------------------------------


def test_checklist_extracts_critical_requirements_bullets():
    expected = (
        "Critical Requirements:\n"
        "- Deployment must use 3 replicas\n"
        "- Service exposes port 8080\n"
    )
    assert extract_checklist_items(expected, use_mcp=True) == [
        "Deployment must use 3 replicas",
        "Service exposes port 8080",
    ]


def test_checklist_stops_at_expected_manifest_marker():
    expected = (
        "Critical Requirements:\n"
        "- Keep replicas at 3\n"
        "Expected Manifest Generated:\n"
        "- apiVersion: apps/v1\n"
    )
    assert extract_checklist_items(expected, use_mcp=True) == ["Keep replicas at 3"]


def test_checklist_drops_tool_call_items_when_mcp_disabled():
    expected = (
        "Critical Requirements:\n"
        "- Expected Tool Call: apply_manifest\n"
        "- App is reachable\n"
    )
    assert extract_checklist_items(expected, use_mcp=False) == ["App is reachable"]
    assert extract_checklist_items(expected, use_mcp=True) == [
        "Expected Tool Call: apply_manifest",
        "App is reachable",
    ]


def test_checklist_empty_when_no_bullets():
    assert extract_checklist_items("Some prose without bullets", use_mcp=True) == []


def test_checklist_preserves_trailing_hyphen():
    # lstrip("- ") must not eat a trailing hyphen the way strip("- ") would.
    expected = "Critical Requirements:\n- Deploy to namespace staging-\n"
    assert extract_checklist_items(expected, use_mcp=True) == ["Deploy to namespace staging-"]


# --- evaluate_metrics_batch (deepeval mocked) ---------------------------------


def _metric_result(name, score=1.0, success=True, reason="ok"):
    metric_data = SimpleNamespace(name=name, score=score, success=success, reason=reason)
    test_result = SimpleNamespace(metrics_data=[metric_data])
    return SimpleNamespace(test_results=[test_result])


def _evaluate_by_metric_name(successes=None):
    """Build an order-agnostic ``evaluate`` side effect.

    The pipeline always calls ``evaluate([tc], metrics=[m])`` with a single
    metric, so the result is derived from that metric's real ``name`` rather than
    call order. The reported name carries DeepEval's ``" [GEval]"`` suffix so the
    test actually exercises the suffix stripping. ``successes`` optionally maps a
    metric name (pre-suffix) to its success bool (default True).

    Args:
        successes: Optional ``{metric_name: success_bool}`` overrides.

    Returns:
        A callable suitable for ``evaluate``'s ``side_effect``.
    """
    successes = successes or {}

    def _side_effect(test_cases, metrics):
        metric = metrics[0]
        name = metric.name
        return _metric_result(f"{name} [GEval]", success=successes.get(name, True))

    return _side_effect


def _base_result(**overrides):
    res = {
        "input": "deploy the app",
        "output": "done, applied to cluster",
        "trajectory": [{"tool": "apply"}],
        "expected_output": "App deployed",
        "latency": 1.0,
        "name": "case-1",
        "retrieval_context": [],
        "tools": ["apply"],
    }
    res.update(overrides)
    return res


def test_batch_scores_outcome_and_tool(mocker):
    mocker.patch.object(pipeline, "get_bool", return_value=True)
    mocker.patch.object(
        pipeline,
        "build_outcome_validity_metric",
        return_value=SimpleNamespace(name="OutcomeValidity"),
    )
    mocker.patch.object(
        pipeline,
        "build_tool_invocation_metric",
        return_value=SimpleNamespace(name="ToolInvocation"),
    )
    mocker.patch.object(pipeline, "LLMTestCase")
    # Order-agnostic: result is keyed off the metric name, and the reported name
    # carries DeepEval's " [GEval]" suffix so the strip is actually exercised.
    mocker.patch.object(pipeline, "evaluate", side_effect=_evaluate_by_metric_name())
    judge = MagicMock()
    results = [_base_result(expected_output="App deployed")]  # no bullets

    evaluate_metrics_batch(results, judge)

    scores = results[0]["scores"]
    assert "OutcomeValidity" in scores
    assert "ToolInvocation" in scores
    assert "OutcomeValidity [GEval]" not in scores
    assert "ToolInvocation [GEval]" not in scores
    assert "ChecklistScore" not in scores


def test_batch_skips_tool_when_mcp_disabled(mocker):
    mocker.patch.object(pipeline, "get_bool", return_value=False)
    mocker.patch.object(
        pipeline,
        "build_outcome_validity_metric",
        return_value=SimpleNamespace(name="OutcomeValidity"),
    )
    mocker.patch.object(
        pipeline,
        "build_tool_invocation_metric",
        return_value=SimpleNamespace(name="ToolInvocation"),
    )
    mocker.patch.object(pipeline, "LLMTestCase")
    evaluate = mocker.patch.object(
        pipeline, "evaluate", side_effect=_evaluate_by_metric_name()
    )
    judge = MagicMock()
    results = [_base_result()]

    evaluate_metrics_batch(results, judge)

    # Only the outcome evaluation runs.
    assert evaluate.call_count == 1
    assert "OutcomeValidity" in results[0]["scores"]
    assert "ToolInvocation" not in results[0]["scores"]


def test_batch_computes_checklist_score(mocker):
    mocker.patch.object(pipeline, "get_bool", return_value=True)
    mocker.patch.object(
        pipeline,
        "build_outcome_validity_metric",
        return_value=SimpleNamespace(name="OutcomeValidity"),
    )
    mocker.patch.object(
        pipeline,
        "build_tool_invocation_metric",
        return_value=SimpleNamespace(name="ToolInvocation"),
    )
    mocker.patch.object(pipeline, "LLMTestCase")
    # Give the dynamic GEval metric a stable name so success can be matched.
    mocker.patch.object(
        pipeline, "GEval", side_effect=lambda **kw: SimpleNamespace(name=kw["name"])
    )
    # Order-agnostic: every evaluated metric (outcome, tool, and the dynamic
    # "Check: replicas=3") resolves by its own name and reports a suffixed key.
    mocker.patch.object(pipeline, "evaluate", side_effect=_evaluate_by_metric_name())
    judge = MagicMock()
    results = [
        _base_result(expected_output="Critical Requirements:\n- replicas=3\n")
    ]

    evaluate_metrics_batch(results, judge)

    scores = results[0]["scores"]
    # The dynamic check key is also stripped of the [GEval] suffix.
    assert "Check: replicas=3" in scores
    assert scores["ChecklistScore"]["score"] == 1.0
    assert scores["ChecklistScore"]["success"] is True


def test_batch_invokes_grounding_and_chaos(mocker):
    mocker.patch.object(pipeline, "get_bool", return_value=True)
    mocker.patch.object(
        pipeline,
        "build_outcome_validity_metric",
        return_value=SimpleNamespace(name="OutcomeValidity"),
    )
    mocker.patch.object(
        pipeline,
        "build_tool_invocation_metric",
        return_value=SimpleNamespace(name="ToolInvocation"),
    )
    mocker.patch.object(pipeline, "LLMTestCase")
    mocker.patch.object(pipeline, "evaluate", side_effect=_evaluate_by_metric_name())
    grounding = mocker.patch.object(pipeline, "evaluate_documentation_grounding")
    retrieval = mocker.patch.object(
        pipeline, "calculate_doc_retrieval_rate", return_value=0.5
    )
    chaos = mocker.patch.object(pipeline, "evaluate_chaos_metrics")
    judge = MagicMock()
    results = [
        _base_result(
            documentation=[{"doc_name": "g", "url": "u", "constraints": []}],
            chaos_spec=[{"fault": "kill"}],
            chaos_report={"injected_fault": "kill"},
            perf_report={"uptime_percentage": 99.9},
        )
    ]

    evaluate_metrics_batch(results, judge)

    grounding.assert_called_once()
    retrieval.assert_called_once()
    chaos.assert_called_once()
    assert results[0]["scores"]["DocRetrievalRate"] == 0.5
