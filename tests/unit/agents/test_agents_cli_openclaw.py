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

"""Unit tests for devops_bench.agents.cli.openclaw."""

from __future__ import annotations

import json
import shlex
import subprocess

import pytest

from devops_bench.agents.cli import openclaw
from devops_bench.core import SubprocessError


@pytest.fixture(autouse=True)
def _no_observe(mocker):
    mocker.patch("deepeval.tracing.observe", lambda *a, **k: (lambda fn: fn))


def _completed(stdout: str) -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(args=["ssh"], returncode=0, stdout=stdout, stderr="")


def test_strip_ansi():
    assert openclaw._strip_ansi("\x1b[31mred\x1b[0m") == "red"


def test_oc_model_id_unset_returns_empty(mocker):
    mocker.patch.dict("os.environ", {}, clear=True)
    assert openclaw._oc_model_id() == ""


def test_oc_model_id_prefixes_provider(mocker):
    mocker.patch.dict(
        "os.environ", {"AGENT_MODEL": "gemini-3", "AGENT_PROVIDER": "gemini"}, clear=True
    )
    # Provider 'gemini' is normalized to oc's 'google'.
    assert openclaw._oc_model_id() == "google/gemini-3"


def test_oc_model_id_passthrough_full_id(mocker):
    mocker.patch.dict("os.environ", {"AGENT_MODEL": "anthropic/claude-x"}, clear=True)
    assert openclaw._oc_model_id() == "anthropic/claude-x"


def test_oc_set_model_cmd_empty_when_unset(mocker):
    mocker.patch.dict("os.environ", {}, clear=True)
    assert openclaw._oc_set_model_cmd("~/bin/oc", " && ") == ""


def test_oc_set_model_cmd_builds_fragment(mocker):
    mocker.patch.dict("os.environ", {"AGENT_MODEL": "google/gemini-3"}, clear=True)
    frag = openclaw._oc_set_model_cmd("~/bin/oc", " && ")
    assert frag == "~/bin/oc models set google/gemini-3 && "


def test_parse_openclaw_session_extracts_tokens_and_trajectory():
    lines = [
        json.dumps(
            {
                "type": "message",
                "message": {"role": "assistant", "usage": {"total": 7}},
            }
        ),
        json.dumps(
            {
                "type": "message",
                "message": {
                    "content": [
                        {"functionCall": {"name": "kubectl", "args": {"verb": "get"}}},
                        {"functionResponse": {"name": "kubectl", "response": "ok"}},
                    ]
                },
            }
        ),
    ]
    tokens, trajectory = openclaw._parse_openclaw_session("\n".join(lines))

    assert tokens == {"total": 7}
    assert trajectory[0] == {"name": "kubectl", "args": {"verb": "get"}, "status": "called"}
    assert trajectory[1] == {"name": "kubectl", "output": "ok", "status": "response"}


def test_parse_openclaw_session_tolerates_null_content():
    # Tool-only assistant turns can carry content: null; must not raise.
    line = json.dumps(
        {"type": "message", "message": {"role": "assistant", "content": None, "usage": {"t": 1}}}
    )
    tokens, trajectory = openclaw._parse_openclaw_session(line)

    assert tokens == {"t": 1}
    assert trajectory == []


def test_run_openclaw_agent_ssh_success(mocker):
    agent_stdout = "sessionFile=/tmp/session.jsonl\n"
    session_stdout = json.dumps(
        {"type": "message", "message": {"role": "assistant", "usage": {"total": 3}}}
    )
    mock_run = mocker.patch.object(
        openclaw,
        "run",
        side_effect=[_completed(agent_stdout), _completed(session_stdout)],
    )
    mocker.patch.dict("os.environ", {}, clear=True)

    result = openclaw.run_openclaw_agent("do a thing", agent_name="operator")

    assert "sessionFile" in result["output"]
    assert result["tokens"] == {"total": 3}
    # Two SSH calls: run the agent, then cat the session file.
    assert mock_run.call_count == 2
    first_cmd = mock_run.call_args_list[0].args[0]
    assert first_cmd[0] == "ssh"


def test_run_openclaw_agent_ssh_error(mocker):
    mocker.patch.object(
        openclaw,
        "run",
        side_effect=SubprocessError(["ssh"], returncode=255, stdout="o", stderr="conn refused"),
    )
    mocker.patch.dict("os.environ", {}, clear=True)

    result = openclaw.run_openclaw_agent("p")

    assert result["output"].startswith("Error:")
    assert "conn refused" in result["output"]
    assert result["trajectory"] == []


def test_run_openclaw_agent_ssh_quotes_prompt_and_agent(mocker):
    mock_run = mocker.patch.object(openclaw, "run", return_value=_completed("no session here"))
    mocker.patch.dict("os.environ", {}, clear=True)

    # Prompt with a single quote + spaces would break naive '{prompt}' interpolation.
    openclaw.run_openclaw_agent("delete the 'prod' pod now", agent_name="op erator")

    remote_command = mock_run.call_args_list[0].args[0][-1]
    # Prompt is shlex-quoted, so the raw unbalanced single-quote form is absent...
    assert "-m 'delete the 'prod' pod now'" not in remote_command
    # ...and the quoted form is present and reversible via shlex.
    assert shlex.quote("delete the 'prod' pod now") in remote_command
    # Agent name is quoted in both the cleanup dir and the --agent flag.
    assert shlex.quote("op erator") in remote_command
    assert "agents/operator/sessions" not in remote_command


def test_run_openclaw_agent_ssh_handles_oserror(mocker):
    # ssh binary missing -> OSError, which core.subprocess.run does not wrap.
    mocker.patch.object(openclaw, "run", side_effect=FileNotFoundError("ssh not found"))
    mocker.patch.dict("os.environ", {}, clear=True)

    result = openclaw.run_openclaw_agent("p")

    assert result["output"].startswith("Error:")
    assert "ssh not found" in result["output"]
    assert result["trajectory"] == []


def test_run_openclaw_agent_local_success(mocker):
    agent_stdout = "sessionFile=/tmp/local-session.jsonl\n"
    session_content = json.dumps(
        {"type": "message", "message": {"role": "assistant", "usage": {"total": 9}}}
    )
    mock_sub = mocker.patch.object(
        openclaw.subprocess,
        "run",
        return_value=_completed(agent_stdout),
    )
    mocker.patch("os.path.expanduser", side_effect=lambda p: p)
    mocker.patch("builtins.open", mocker.mock_open(read_data=session_content))

    result = openclaw.run_openclaw_agent_local("p", agent_name="operator")

    assert result["tokens"] == {"total": 9}
    # Local path uses bash so nvm can be sourced.
    assert mock_sub.call_args.kwargs["shell"] is True
    assert mock_sub.call_args.kwargs["executable"] == "/bin/bash"


def test_run_openclaw_agent_local_error(mocker):
    mocker.patch.object(
        openclaw.subprocess,
        "run",
        side_effect=subprocess.CalledProcessError(1, "cmd", output="o", stderr="bad"),
    )

    result = openclaw.run_openclaw_agent_local("p")

    assert result["output"].startswith("Error:")
    assert "bad" in result["output"]


def test_run_openclaw_agent_local_handles_oserror(mocker):
    # /bin/bash missing -> OSError, distinct from CalledProcessError.
    mocker.patch.object(
        openclaw.subprocess, "run", side_effect=FileNotFoundError("/bin/bash missing")
    )

    result = openclaw.run_openclaw_agent_local("p")

    assert result["output"].startswith("Error:")
    assert "/bin/bash missing" in result["output"]


def test_openclaw_agent_run_dispatches_ssh(mocker):
    mock_ssh = mocker.patch.object(
        openclaw, "run_openclaw_agent", return_value={"output": "ssh"}
    )
    mocker.patch.dict("os.environ", {}, clear=True)

    result = openclaw.OpenClawAgent().run("p")

    assert result == {"output": "ssh"}
    mock_ssh.assert_called_once()


def test_openclaw_agent_run_dispatches_local(mocker):
    mock_local = mocker.patch.object(
        openclaw, "run_openclaw_agent_local", return_value={"output": "local"}
    )
    mocker.patch.dict("os.environ", {"OPENCLAW_LOCAL": "true"}, clear=True)

    result = openclaw.OpenClawAgent().run("p")

    assert result == {"output": "local"}
    mock_local.assert_called_once()
