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

"""OpenClaw CLI agent harness (``oc agent``) over SSH or co-located locally."""

from __future__ import annotations

import getpass
import json
import os
import re
import shlex
import subprocess
import time

from devops_bench.agents.base import AGENTS, AgentHarness
from devops_bench.core import SubprocessError, get_bool, get_env, get_logger
from devops_bench.core.subprocess import run

__all__ = [
    "OpenClawAgent",
    "run_openclaw_agent",
    "run_openclaw_agent_local",
]

_log = get_logger("agents.cli.openclaw")

# OpenClaw emits ANSI-colored debug logs to stdout. The escape codes corrupt the
# `sessionFile=...` path extraction (the regex would capture the trailing reset
# code) and add noise to the text the judge grades, so strip them first.
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def _strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text)


def _oc_model_id() -> str:
    """Resolve the OpenClaw model id from the harness env, or "".

    ``oc agent`` has no per-invocation model flag, so the model is selected by
    running ``oc models set <id>`` before the agent turn (see
    :func:`_oc_set_model_cmd`). The id flows from config: ``AGENT_MODEL`` (and
    ``AGENT_PROVIDER`` when the model is not already a full ``provider/model``
    id); never hardcoded. Returns oc's ``provider/model`` id (e.g.
    ``google/gemini-3.1-pro-preview``), or "" when ``AGENT_MODEL`` is unset (we
    then leave oc's configured default untouched).
    """
    model = (get_env("AGENT_MODEL") or "").strip()
    if not model:
        return ""
    if "/" not in model:  # allow AGENT_MODEL to be a full oc id (provider/model)
        provider = (get_env("AGENT_PROVIDER") or "google").strip().lower()
        if provider == "gemini":
            provider = "google"
        model = f"{provider}/{model}"
    return model


def _oc_set_model_cmd(oc_bin: str, sep: str) -> str:
    """Shell fragment that points oc at ``AGENT_MODEL`` before the agent runs, or "".

    ``oc models set <id>`` persists the default model in oc's config; the harness
    re-sets it every run, so it stays driven by ``AGENT_MODEL``. ``sep`` joins it
    to the following command (e.g. ``" && "`` for the SSH chain, ``"; "`` for the
    local one).

    Args:
        oc_bin: Path to the ``oc`` binary (already shell-quoted by the caller for
            the local path).
        sep: Separator appended after the fragment.

    Returns:
        The ``oc models set ...<sep>`` fragment, or "" when no model is configured.
    """
    model_id = _oc_model_id()
    if not model_id:
        return ""
    return f"{oc_bin} models set {shlex.quote(model_id)}{sep}"


def _parse_openclaw_session(session_content: str) -> tuple[dict, list]:
    """Parse an OpenClaw session JSONL into ``(tokens, trajectory)``.

    Args:
        session_content: Raw JSONL contents of a session file.

    Returns:
        A ``(tokens, trajectory)`` tuple; ``tokens`` is the last assistant usage
        dict seen and ``trajectory`` is the ordered list of tool-call dicts.
    """
    tokens: dict = {}
    trajectory: list = []
    for line in session_content.strip().split("\n"):
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue

        # Extract tokens from assistant message
        if data.get("type") == "message" and data.get("message", {}).get("role") == "assistant":
            usage = data.get("message", {}).get("usage")
            if usage:
                tokens = usage

        # Extract trajectory
        if data.get("type") == "message":
            msg = data.get("message", {})
            # Tool-only assistant turns can carry ``content: null``; coalesce to a
            # list so iteration never raises.
            content = msg.get("content") or []
            for part in content:
                if not isinstance(part, dict):
                    continue
                if "functionCall" in part:
                    call = part["functionCall"]
                    trajectory.append(
                        {"name": call.get("name"), "args": call.get("args"), "status": "called"}
                    )
                elif part.get("type") == "toolCall":
                    trajectory.append(
                        {
                            "name": part.get("name"),
                            "args": part.get("arguments"),
                            "status": "called",
                        }
                    )
                elif "functionResponse" in part:
                    resp = part["functionResponse"]
                    trajectory.append(
                        {
                            "name": resp.get("name"),
                            "output": resp.get("response"),
                            "status": "response",
                        }
                    )

    return tokens, trajectory


def run_openclaw_agent(prompt: str, context: dict | None = None, agent_name: str = "main") -> dict:
    """Run the OpenClaw agent on a GCE VM via SSH.

    Connection details and the model are read from the environment
    (``OPENCLAW_SSH_*``, ``GCP_PROJECT_ID``, ``AGENT_MODEL``/``AGENT_PROVIDER``).

    Args:
        prompt: Task prompt for the agent.
        context: Ignored; accepted for interface symmetry with the local runner.
        agent_name: oc agent profile to invoke.

    Returns:
        The standardized result dict. On a non-zero ``oc`` exit the dict carries
        the error text in ``output`` and empty trajectory/token fields.
    """
    from deepeval.tracing import observe

    @observe()
    def _run() -> dict:
        current_user = getpass.getuser()
        project_id = get_env("GCP_PROJECT_ID", "simrankaurk-gke-dev")

        ssh_user = get_env("OPENCLAW_SSH_USER", f"{current_user}_google_com")
        vm_host = get_env(
            "OPENCLAW_VM_HOST",
            f"nic0.claw-ubuntu.us-central1-a.c.{project_id}.internal.gcpnode.com",
        )
        ssh_key = get_env("OPENCLAW_SSH_KEY", os.path.expanduser("~/.ssh/google_compute_engine"))

        # shlex.quote every value interpolated into the remote shell string so
        # prompts/agent names containing quotes, spaces, or newlines neither break
        # parsing nor inject commands. The session-cleanup dir uses the actual
        # agent_name (not a hardcoded "operator").
        set_model = _oc_set_model_cmd("~/bin/oc", " && ")
        quoted_agent = shlex.quote(agent_name)
        remote_command = (
            f"rm -rf ~/.openclaw/agents/{quoted_agent}/sessions/* && "
            'export NVM_DIR="$HOME/.nvm" && '
            '[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh" && '
            f"{set_model}~/bin/oc --log-level debug agent --local "
            f"--agent {quoted_agent} -m {shlex.quote(prompt)}"
        )

        ssh_cmd = ["ssh", "-i", ssh_key, f"{ssh_user}@{vm_host}", remote_command]

        start_time = time.time()
        try:
            result = run(ssh_cmd)
        except (SubprocessError, OSError) as exc:
            return {
                "output": f"Error: {exc}",
                "latency": time.time() - start_time,
                "tokens": {},
                "tools": {},
                "trajectory": [],
                "skills": [],
            }

        latency = time.time() - start_time
        output = _strip_ansi(result.stdout)

        match = re.search(r"sessionFile=([^ \n]+)", output)
        tokens: dict = {}
        trajectory: list = []
        if match:
            session_file = match.group(1)
            read_cmd = [
                "ssh",
                "-i",
                ssh_key,
                f"{ssh_user}@{vm_host}",
                f"cat {shlex.quote(session_file)}",
            ]
            try:
                read_result = run(read_cmd)
                tokens, trajectory = _parse_openclaw_session(read_result.stdout)
            except (SubprocessError, OSError) as exc:
                _log.warning("Failed to read session file: %s", exc)

        return {
            "output": output,
            "latency": latency,
            "tokens": tokens,
            "tools": {},
            "trajectory": trajectory,
            "skills": [],
        }

    return _run()


def run_openclaw_agent_local(
    prompt: str, context: dict | None = None, agent_name: str = "operator"
) -> dict:
    """Run the OpenClaw agent locally via a bash subprocess (no SSH).

    Used when the harness, the kind cluster, and the agent are co-located on the
    same host (selected by ``OPENCLAW_LOCAL=true``). A bash shell is required so
    nvm can be sourced before invoking ``oc``; ``core.subprocess.run`` only takes
    list args, so this path uses ``subprocess.run(shell=True)`` directly with
    every interpolated value ``shlex.quote``-escaped.

    Args:
        prompt: Task prompt for the agent.
        context: Ignored; accepted for interface symmetry with the SSH runner.
        agent_name: oc agent profile to invoke.

    Returns:
        The standardized result dict (see :func:`run_openclaw_agent`).
    """
    from deepeval.tracing import observe

    @observe()
    def _run() -> dict:
        oc_bin = get_env("OPENCLAW_BIN", os.path.expanduser("~/bin/oc"))
        sessions_glob = os.path.expanduser(f"~/.openclaw/agents/{agent_name}/sessions")

        # Mirror the remote command: clear prior sessions, load nvm, run the agent.
        # shlex.quote everything interpolated into the shell string — prompts contain
        # single quotes and newlines, which would otherwise break shell parsing.
        local_command = (
            f"rm -rf {shlex.quote(sessions_glob)}/* 2>/dev/null; "
            'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; '
            f"{_oc_set_model_cmd(shlex.quote(oc_bin), '; ')}"
            f"{shlex.quote(oc_bin)} --log-level debug agent --local "
            f"--agent {shlex.quote(agent_name)} -m {shlex.quote(prompt)}"
        )

        start_time = time.time()
        try:
            result = subprocess.run(
                local_command,
                shell=True,  # noqa: S602 - bash needed to source nvm; inputs are shlex-quoted
                executable="/bin/bash",
                capture_output=True,
                text=True,
                check=True,
            )
        except subprocess.CalledProcessError as exc:
            return {
                "output": f"Error: {exc.stderr}\nStdout: {exc.stdout}",
                "latency": time.time() - start_time,
                "tokens": {},
                "tools": {},
                "trajectory": [],
                "skills": [],
            }
        except OSError as exc:
            # e.g. /bin/bash missing or not executable.
            return {
                "output": f"Error: {exc}",
                "latency": time.time() - start_time,
                "tokens": {},
                "tools": {},
                "trajectory": [],
                "skills": [],
            }

        latency = time.time() - start_time
        output = _strip_ansi(result.stdout)

        match = re.search(r"sessionFile=([^ \n]+)", output)
        tokens: dict = {}
        trajectory: list = []
        if match:
            session_file = os.path.expanduser(match.group(1))
            try:
                with open(session_file) as f:
                    tokens, trajectory = _parse_openclaw_session(f.read())
            except OSError as exc:
                _log.warning("Failed to read local session file %s: %s", session_file, exc)

        return {
            "output": output,
            "latency": latency,
            "tokens": tokens,
            "tools": {},
            "trajectory": trajectory,
            "skills": [],
        }

    return _run()


@AGENTS.register("openclaw")
class OpenClawAgent(AgentHarness):
    """OpenClaw agent harness driving the ``oc`` binary.

    Runs ``oc`` on a remote GCE VM over SSH by default; set ``OPENCLAW_LOCAL=true``
    to run it locally when the harness and agent are co-located.

    Args:
        agent_name: oc agent profile to invoke (``operator`` by default).
    """

    def __init__(self, agent_name: str = "operator") -> None:
        self.agent_name = agent_name

    def run(self, prompt: str, context: dict | None = None) -> dict:
        """Run the OpenClaw agent, selecting SSH or local transport from env.

        ``OPENCLAW_LOCAL=true`` selects the co-located local runner; otherwise the
        SSH runner is used.
        """
        if get_bool("OPENCLAW_LOCAL"):
            return run_openclaw_agent_local(prompt, context, agent_name=self.agent_name)
        return run_openclaw_agent(prompt, context, agent_name=self.agent_name)
