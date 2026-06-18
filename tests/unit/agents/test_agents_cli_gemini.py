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


def test_parse_gemini_cli_output_with_brace_noise_around_json():
    # Log lines containing braces both before AND after the real payload would
    # corrupt a greedy ({.*}) match; the balanced-object scan must still find it.
    payload = json.dumps(
        {
            "response": "the answer",
            "session_id": "sid-9",
            "stats": {"models": {"m": {"tokens": {"total": 5}}}, "tools": {"t": 2}},
        }
    )
    raw = (
        'DEBUG starting {context: "noise"}\n'
        "INFO config={enabled: true}\n"
        f"{payload}\n"
        'WARN trailing {leftover: "junk"} done\n'
    )
    parsed = gemini.parse_gemini_cli_output(raw)

    assert parsed["output"] == "the answer"
    assert parsed["session_id"] == "sid-9"
    assert parsed["tokens"] == {"total": 5}
    assert parsed["tools"] == {"t": 2}


def test_parse_gemini_cli_output_ignores_braces_inside_strings():
    # A brace inside a JSON string value must not throw off brace-balance scanning.
    payload = json.dumps({"response": "use {curly} braces", "stats": {}})
    parsed = gemini.parse_gemini_cli_output("noise\n" + payload)
    assert parsed["output"] == "use {curly} braces"


def test_extract_trajectory_missing_dir_returns_empty(mocker):
    mocker.patch("os.path.exists", return_value=False)
    res = gemini.extract_trajectory_from_session("abc-123")
    assert res == {"trajectory": [], "skills": []}


def test_extract_trajectory_skill_parent_folder_fallback(mocker):
    # A SKILL.md path with no "skills" dir: the skill name is the parent folder.
    session_line = json.dumps(
        {
            "type": "gemini",
            "toolCalls": [
                {
                    "name": "read_file",
                    "args": {"file_path": "/plugin/my-skill/SKILL.md"},
                    "status": "done",
                },
                {
                    "name": "read_file",
                    "args": {"file_path": "/repo/skills/other-skill/guide.md"},
                    "status": "done",
                },
            ],
        }
    )
    mocker.patch("os.path.exists", return_value=True)
    mocker.patch("glob.glob", return_value=["/fake/session-x-abc.jsonl"])
    mocker.patch("builtins.open", mocker.mock_open(read_data=session_line))

    res = gemini.extract_trajectory_from_session("abc")

    assert sorted(res["skills"]) == ["my-skill", "other-skill"]
    assert len(res["trajectory"]) == 2


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


def test_run_cli_agent_handles_oserror(mocker):
    # Missing binary -> OSError, which core.subprocess.run does not wrap.
    mocker.patch.object(gemini, "run", side_effect=FileNotFoundError("gemini not found"))

    result = gemini.run_cli_agent("gemini", "p", context=None)

    assert result["output"].startswith("Error:")
    assert "gemini not found" in result["output"]
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


def test_run_cli_agent_gemini_path_with_oc_substring_not_misrouted(mocker):
    # Regression: "/usr/local/bin/gemini" contains the naive "oc" substring
    # (in "local"). The gemini branch must be checked first so this is NOT
    # misrouted to the OpenClaw delegate.
    payload = json.dumps({"response": "ok", "session_id": None, "stats": {}})
    mock_run = mocker.patch.object(gemini, "run", return_value=_completed(payload))
    mock_oc = mocker.patch.object(gemini, "run_openclaw_agent")
    mock_oc_local = mocker.patch.object(gemini, "run_openclaw_agent_local")

    result = gemini.run_cli_agent("/usr/local/bin/gemini", "p", context=None)

    assert result["output"] == "ok"
    mock_run.assert_called_once()
    mock_oc.assert_not_called()
    mock_oc_local.assert_not_called()
    args = mock_run.call_args.args[0]
    assert args[0] == "/usr/local/bin/gemini"
    assert "-o" in args and "json" in args


def test_run_cli_agent_generic_binary_feeds_goal_on_stdin(mocker):
    # A generic "binary" agent (neither gemini nor openclaw/oc) gets neither -p
    # nor flags; legacy fed the goal/context as JSON on stdin. Pin that contract.
    mock_run = mocker.patch.object(
        gemini, "run", return_value=_completed("raw agent output")
    )
    mock_oc = mocker.patch.object(gemini, "run_openclaw_agent")
    mock_oc_local = mocker.patch.object(gemini, "run_openclaw_agent_local")

    result = gemini.run_cli_agent("/opt/agents/binary", "do it", context={"k": "v"})

    assert result["output"] == "raw agent output"
    mock_oc.assert_not_called()
    mock_oc_local.assert_not_called()
    # No CLI flags appended for a generic binary.
    args = mock_run.call_args.args[0]
    assert args == ["/opt/agents/binary"]
    # Goal + context delivered on stdin as JSON.
    stdin = mock_run.call_args.kwargs["input"]
    assert json.loads(stdin) == {"goal": "do it", "context": {"k": "v"}}


def test_run_cli_agent_gemini_no_stdin(mocker):
    # The gemini branch must NOT send anything on stdin (it uses -p).
    payload = json.dumps({"response": "x", "session_id": None, "stats": {}})
    mock_run = mocker.patch.object(gemini, "run", return_value=_completed(payload))

    gemini.run_cli_agent("gemini", "p", context={"k": "v"})

    assert mock_run.call_args.kwargs["input"] is None


def test_gemini_cli_agent_run(mocker):
    payload = json.dumps({"response": "ok", "session_id": None, "stats": {}})
    mocker.patch.object(gemini, "run", return_value=_completed(payload))

    agent = gemini.GeminiCliAgent(agent_target="gemini")
    result = agent.run("hello")

    assert result["output"] == "ok"
