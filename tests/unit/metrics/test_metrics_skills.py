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

"""Tests for skill loading and GEval metric construction (outcome + tool)."""

from __future__ import annotations

from importlib import resources
from unittest.mock import MagicMock

import pytest

from devops_bench.metrics import _skills, outcome_validity, tool_invocation
from devops_bench.metrics.tool_invocation import TOOL_INVOCATION_THRESHOLD


def test_skills_are_packaged_resources():
    # The judge skills ship as package data under devops_bench.skills so they
    # resolve via importlib.resources under pip install, not a repo-relative path.
    pkg = resources.files(_skills.SKILLS_PACKAGE)
    assert (pkg / "outcome-validity-checklist.md").is_file()
    assert (pkg / "tool-invocation-skill.md").is_file()


def test_load_outcome_criteria_reads_real_skill():
    text = outcome_validity.load_outcome_criteria()
    assert "Evaluation Criteria" in text


def test_load_tool_criteria_reads_real_skill():
    text = tool_invocation.load_tool_criteria()
    assert "Evaluation Criteria" in text


def test_load_skill_text_missing_raises():
    with pytest.raises(FileNotFoundError):
        _skills.load_skill_text("does-not-exist.md")


def test_build_outcome_validity_metric(mocker):
    geval_cls = mocker.patch.object(outcome_validity, "GEval")
    mocker.patch.object(outcome_validity, "load_outcome_criteria", return_value="CRIT")
    model = MagicMock()

    outcome_validity.build_outcome_validity_metric(model)

    kwargs = geval_cls.call_args.kwargs
    assert kwargs["name"] == "OutcomeValidity"
    assert kwargs["criteria"] == "CRIT"
    assert kwargs["model"] is model


def test_build_tool_invocation_metric_applies_threshold(mocker):
    geval_cls = mocker.patch.object(tool_invocation, "GEval")
    mocker.patch.object(tool_invocation, "load_tool_criteria", return_value="CRIT")
    model = MagicMock()

    tool_invocation.build_tool_invocation_metric(model)

    kwargs = geval_cls.call_args.kwargs
    assert kwargs["name"] == "ToolInvocation"
    assert kwargs["threshold"] == TOOL_INVOCATION_THRESHOLD
    assert kwargs["model"] is model
