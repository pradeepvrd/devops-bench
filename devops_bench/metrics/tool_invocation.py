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

"""ToolInvocation GEval metric and its skill loading."""

from __future__ import annotations

from pathlib import Path

from deepeval.metrics import GEval
from deepeval.test_case import SingleTurnParams

from devops_bench.core import get_logger

__all__ = [
    "TOOL_SKILL_FILENAME",
    "TOOL_INVOCATION_THRESHOLD",
    "load_tool_criteria",
    "build_tool_invocation_metric",
]

TOOL_SKILL_FILENAME = "tool-invocation-skill.md"
TOOL_INVOCATION_THRESHOLD = 0.8

_log = get_logger("metrics.tool_invocation")

# parents: [0]=metrics, [1]=devops_bench, [2]=repo root.
_REPO_ROOT = Path(__file__).resolve().parents[2]


def load_tool_criteria() -> str:
    """Read the tool-invocation skill from the repo ``skills`` dir.

    Returns:
        The full markdown text used as the GEval criteria.

    Raises:
        FileNotFoundError: If the skill file is missing.
    """
    path = _REPO_ROOT / "skills" / TOOL_SKILL_FILENAME
    if not path.is_file():
        raise FileNotFoundError(f"Tool invocation skill not found at {path}")
    return path.read_text()


def build_tool_invocation_metric(model) -> GEval:
    """Build the ToolInvocation GEval metric.

    Args:
        model: A ``DeepEvalBaseLLM`` judge model.

    Returns:
        A configured :class:`~deepeval.metrics.GEval` instance with the
        tool-invocation pass threshold applied.
    """
    return GEval(
        name="ToolInvocation",
        criteria=load_tool_criteria(),
        threshold=TOOL_INVOCATION_THRESHOLD,
        evaluation_params=[
            SingleTurnParams.INPUT,
            SingleTurnParams.ACTUAL_OUTPUT,
        ],
        model=model,
    )
