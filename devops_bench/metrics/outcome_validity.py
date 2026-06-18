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

"""OutcomeValidity GEval metric and its checklist skill loading."""

from __future__ import annotations

from deepeval.metrics import GEval
from deepeval.test_case import SingleTurnParams

from devops_bench.core import get_logger
from devops_bench.metrics._skills import load_skill_text

__all__ = ["OUTCOME_SKILL_FILENAME", "load_outcome_criteria", "build_outcome_validity_metric"]

OUTCOME_SKILL_FILENAME = "outcome-validity-checklist.md"

_log = get_logger("metrics.outcome_validity")


def load_outcome_criteria() -> str:
    """Read the outcome-validity checklist skill packaged with the project.

    Returns:
        The full markdown text used as the GEval criteria.

    Raises:
        FileNotFoundError: If the packaged skill file is missing.
    """
    return load_skill_text(OUTCOME_SKILL_FILENAME)


def build_outcome_validity_metric(model) -> GEval:
    """Build the OutcomeValidity GEval metric.

    Args:
        model: A ``DeepEvalBaseLLM`` judge model.

    Returns:
        A configured :class:`~deepeval.metrics.GEval` instance.
    """
    return GEval(
        name="OutcomeValidity",
        criteria=load_outcome_criteria(),
        evaluation_params=[
            SingleTurnParams.INPUT,
            SingleTurnParams.ACTUAL_OUTPUT,
        ],
        model=model,
    )
