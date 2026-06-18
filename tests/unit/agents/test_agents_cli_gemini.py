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

"""Unit tests for devops_bench.agents.cli.gemini."""

from __future__ import annotations

import json
import subprocess

import pytest

from devops_bench.agents.cli import gemini
from devops_bench.core import SubprocessError


@pytest.fixture(autouse=True)
def _no_observe(mocker):
    # deepeval's @observe is imported lazily inside the functions; replace it with
    # an identity decorator so no real tracing runs.
    mocker.patch("deepeval.tracing.observe", lambda *a, **k: (lambda fn: fn))


def _completed(stdout: str) -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(args=["gemini"], returncode=0, stdout=stdout, stderr="")


def test_parse_gemini_cli_output_extracts_stats():
    raw = (
        "log noise line\n"
        + json.dumps(
            {
                "response": "hello world",
                "session_id": "abc-123",
                "stats": {
                    "models": {"gemini-x": {"tokens": {"total": 42}}},
                    "tools": {"mcp_gke_list_clusters": 1},
                },
            }
        )
    )
    parsed = gemini.parse_gemini_cli_output(raw)

    assert parsed["output"] == "hello world"
    assert parsed["tokens"] == {"total": 42}
    assert parsed["tools"] == {"mcp_gke_list_clusters": 1}
    assert parsed["session_id"] == "abc-123"


def test_parse_gemini_cli_output_falls_back_on_bad_json():
    parsed = gemini.parse_gemini_cli_output("not json at all")
    assert parsed["output"] == "not json at all"
    assert parsed["tokens"] == {}
    assert parsed["session_id"] is None


def test_extract_trajectory_missing_dir_returns_empty(mocker):
    mocker.patch("os.path.exists", return_value=False)
    res = gemini.extract_trajectory_from_session("abc-123")
    assert res == {"trajectory": [], "skills": []}


def test_run_cli_agent_gemini_success(mocker):
    payload = json.dumps(
        {"response": "done", "session_id": None, "stats": {"models": {}, "tools": {}}}
    )
    mock_run = mocker.patch.object(gemini, "run", return_value=_completed(payload))

    result = gemini.run_cli_agent("gemini", "do a thing", context={"k": "v"})

    assert result["output"] == "done"
    assert result["trajectory"] == []
    assert result["skills"] == []
    args = mock_run.call_args.args[0]
    assert args[0] == "gemini"
    assert "-o" in args and "json" in args
    assert "-p" in args
    # MCP tools pre-approved by default.
    assert "--allowed-tools" in args


def test_run_cli_agent_gemini_no_mcp(mocker):
    payload = json.dumps({"response": "x", "session_id": None, "stats": {}})
    mock_run = mocker.patch.object(gemini, "run", return_value=_completed(payload))

    gemini.run_cli_agent("gemini", "p", context=None, bench_use_mcp=False)

    args = mock_run.call_args.args[0]
    assert "-e" in args and "none" in args
    assert "--allowed-tools" not in args


def test_run_cli_agent_passes_model_env(mocker):
    payload = json.dumps({"response": "x", "session_id": None, "stats": {}})
    mock_run = mocker.patch.object(gemini, "run", return_value=_completed(payload))
    mocker.patch.dict(
        "os.environ", {"AGENT_MODEL": "gemini-custom", "AGENT_API_KEY": "secret"}, clear=True
    )

    gemini.run_cli_agent("gemini", "p", context=None)

    overlay = mock_run.call_args.kwargs["extra_env"]
    # Model-agnostic: model flows from AGENT_MODEL, never hardcoded.
    assert overlay["GEMINI_MODEL"] == "gemini-custom"
    assert overlay["GOOGLE_API_KEY"] == "secret"
    assert overlay["GEMINI_API_KEY"] == "secret"
    assert overlay["OTEL_SDK_DISABLED"] == "true"


def test_run_cli_agent_handles_subprocess_error(mocker):
    mocker.patch.object(
        gemini, "run", side_effect=SubprocessError(["gemini"], returncode=1, stderr="boom")
    )

    result = gemini.run_cli_agent("gemini", "p", context=None)

    assert result["output"].startswith("Error:")
    assert "boom" in result["output"]
    assert result["trajectory"] == []


def test_run_cli_agent_delegates_to_openclaw(mocker):
    mock_oc = mocker.patch.object(
        gemini, "run_openclaw_agent", return_value={"output": "oc-out"}
    )
    mocker.patch.dict("os.environ", {}, clear=True)  # OPENCLAW_LOCAL unset → SSH path

    result = gemini.run_cli_agent("/usr/bin/openclaw", "p", context={"c": 1})

    assert result == {"output": "oc-out"}
    mock_oc.assert_called_once()


def test_run_cli_agent_delegates_to_openclaw_local(mocker):
    mock_local = mocker.patch.object(
        gemini, "run_openclaw_agent_local", return_value={"output": "local-out"}
    )
    mocker.patch.dict("os.environ", {"OPENCLAW_LOCAL": "true"}, clear=True)

    result = gemini.run_cli_agent("/usr/bin/openclaw", "p", context=None)

    assert result == {"output": "local-out"}
    mock_local.assert_called_once()


def test_gemini_cli_agent_run(mocker):
    payload = json.dumps({"response": "ok", "session_id": None, "stats": {}})
    mocker.patch.object(gemini, "run", return_value=_completed(payload))

    agent = gemini.GeminiCliAgent(agent_target="gemini")
    result = agent.run("hello")

    assert result["output"] == "ok"
