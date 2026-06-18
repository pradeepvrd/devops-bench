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

"""LLM-as-judge scoring for benchmark runs.

The public entry point is :func:`evaluate_metrics_batch`, which scores a batch
of execution results, and :func:`get_judge_model` / :class:`ModelLayerJudge`,
which build the provider-agnostic judge. Names are resolved lazily so importing
this package never eagerly pulls in ``deepeval`` or any provider SDK; the
concrete modules import ``deepeval`` only when first accessed.
"""

from __future__ import annotations

import importlib
from typing import TYPE_CHECKING, Any

__all__ = [
    "ModelLayerJudge",
    "get_judge_model",
    "evaluate_metrics_batch",
    "build_outcome_validity_metric",
    "build_tool_invocation_metric",
    "calculate_doc_retrieval_rate",
    "evaluate_documentation_grounding",
    "evaluate_chaos_metrics",
]

# Public name -> defining submodule, resolved lazily in __getattr__.
_EXPORTS = {
    "ModelLayerJudge": "geval",
    "get_judge_model": "geval",
    "evaluate_metrics_batch": "pipeline",
    "build_outcome_validity_metric": "outcome_validity",
    "build_tool_invocation_metric": "tool_invocation",
    "calculate_doc_retrieval_rate": "grounding",
    "evaluate_documentation_grounding": "grounding",
    "evaluate_chaos_metrics": "chaos_metrics",
}

if TYPE_CHECKING:  # pragma: no cover - import only for type checkers
    from devops_bench.metrics.chaos_metrics import evaluate_chaos_metrics
    from devops_bench.metrics.geval import ModelLayerJudge, get_judge_model
    from devops_bench.metrics.grounding import (
        calculate_doc_retrieval_rate,
        evaluate_documentation_grounding,
    )
    from devops_bench.metrics.outcome_validity import build_outcome_validity_metric
    from devops_bench.metrics.pipeline import evaluate_metrics_batch
    from devops_bench.metrics.tool_invocation import build_tool_invocation_metric


def __getattr__(name: str) -> Any:
    """Lazily import and return a public metrics symbol on first access."""
    module_name = _EXPORTS.get(name)
    if module_name is None:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    module = importlib.import_module(f"{__name__}.{module_name}")
    return getattr(module, name)


def __dir__() -> list[str]:
    return sorted(__all__)
