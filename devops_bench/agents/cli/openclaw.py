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

"""OpenClaw CLI agent harness driving the ``oc`` binary (local-only).

The agent always invokes ``oc`` locally — the SSH transport from the legacy
runner is gone (a deployment concern, not part of the agent abstraction).

Trajectory extraction uses the official session commands documented in
``docs/openclaw/sessions.md`` — *not* the debug-log ``sessionFile=`` scrape,
and *not* ``sessions tail`` (which redacts tool args / result bodies):

1. Wipe ``~/.openclaw/agents/<name>/sessions/*`` before the run so exactly
   one fresh session exists afterward.
2. Run ``oc agent --local --agent <name> -m <prompt>``.
3. Locate the session: ``oc sessions --agent <name> --json`` (single row).
4. Export the bundle: ``oc sessions export-trajectory --session-key <key>
   --workspace <tmpdir> --json``.
5. Parse the exported trajectory JSONL into canonical :class:`ToolCall`
   entries; pull tokens / output from the bundle.

The ``oc`` binary is a custom alias on the user's host; on any extraction
miss the failure is recorded on ``AgentResult.errors`` rather than returning
a silent-empty trajectory.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import tempfile
from pathlib import Path

from devops_bench.agents.base import AGENTS, AgentHarness
from devops_bench.agents.capabilities import RulesMixin
from devops_bench.agents.config import AgentConfig
from devops_bench.agents.result import AgentResult, ToolCall
from devops_bench.core import SubprocessError, get_logger
from devops_bench.core.subprocess import run

__all__ = ["OpenClawAgent", "parse_trajectory_export"]

_log = get_logger("agents.cli.openclaw")

# OpenClaw emits ANSI-colored debug logs to stdout. The escape codes add noise
# to the text the judge grades, so strip them before returning the output.
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def _strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text)


def _oc_model_id(config: AgentConfig) -> str:
    """Resolve the ``provider/model`` id ``oc models set`` expects.

    ``oc agent`` has no per-invocation model flag, so the model is selected by
    running ``oc models set <id>`` before the agent turn. The id flows from
    ``config.model`` / ``config.provider`` — never hardcoded. Returns oc's
    canonical ``provider/model`` id (e.g. ``google/gemini-2.5-pro``), or ``""``
    when no model was configured (oc's stored default is then left untouched).
    """
    model = (config.model or "").strip()
    if not model:
        return ""
    if "/" in model:  # already a full oc id
        return model
    provider = (config.provider or "google").strip().lower()
    if provider == "gemini":
        provider = "google"
    return f"{provider}/{model}"


def _build_local_command(
    config: AgentConfig, prompt: str, agent_name: str, oc_bin: str
) -> str:
    """Build the bash command that wipes sessions, sets the model, and runs ``oc``.

    Every interpolated value is ``shlex.quote``d so prompts/agent names
    containing single quotes, spaces, or newlines neither break parsing nor
    inject commands. ``bash -c`` is required so ``nvm.sh`` can be sourced to
    expose the right Node toolchain before invoking ``oc``.

    Args:
        config: Resolved :class:`AgentConfig`.
        prompt: Task prompt for the agent.
        agent_name: ``oc`` agent profile (e.g. ``"operator"``).
        oc_bin: Path to the ``oc`` binary.

    Returns:
        A single bash command string ready for ``subprocess.run(shell=True)``.
    """
    quoted_oc = shlex.quote(oc_bin)
    sessions_dir = os.path.expanduser(f"~/.openclaw/agents/{agent_name}/sessions")
    model_id = _oc_model_id(config)
    # Chain `models set` with `&&` so a failed model-set aborts the run; the
    # bash non-zero exit then surfaces via `completed.returncode` and lands on
    # `AgentResult.errors` rather than silently falling through to oc's stored
    # default (which would invalidate the benchmark arm).
    set_model = (
        f"{quoted_oc} models set {shlex.quote(model_id)} && " if model_id else ""
    )
    return (
        # Wipe prior sessions so exactly one fresh session exists afterward.
        f"rm -rf {shlex.quote(sessions_dir)}/* 2>/dev/null; "
        # Source nvm so the Node-based oc binary's runtime is available.
        'export NVM_DIR="$HOME/.nvm"; '
        '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; '
        f"{set_model}"
        f"{quoted_oc} --log-level debug agent --local "
        f"--agent {shlex.quote(agent_name)} -m {shlex.quote(prompt)}"
    )


def parse_trajectory_export(jsonl_text: str) -> tuple[list[dict], dict, list[str]]:
    """Parse an ``oc sessions export-trajectory`` JSONL into the canonical shape.

    The bundle's trajectory file is line-delimited JSON. Each line carries
    either a ``tool_call`` (with ``name`` + ``args``) or a ``tool_result``
    (with the matching ``id`` and ``output``); message lines may carry
    ``usage`` token counts. The parser folds matching call/result pairs into
    one :class:`ToolCall` so the metrics layer sees the canonical trajectory
    other agents emit, and surfaces parse misses on the ``errors`` list.

    Args:
        jsonl_text: Raw contents of the trajectory JSONL inside the export
            bundle.

    Returns:
        A ``(trajectory, tokens, errors)`` tuple. ``trajectory`` is a list of
        ``ToolCall.to_dict()`` mappings.
    """
    tokens: dict = {}
    errors: list[str] = []
    pending: dict[str, ToolCall] = {}
    trajectory: list[ToolCall] = []

    for lineno, raw in enumerate(jsonl_text.splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError as exc:
            errors.append(f"trajectory line {lineno} parse error: {exc}")
            continue
        if not isinstance(entry, dict):
            continue

        etype = entry.get("type") or entry.get("event")

        if etype in ("tool_call", "toolCall", "function_call"):
            call_id = entry.get("id") or entry.get("call_id") or ""
            args = entry.get("args")
            if args is None:
                args = entry.get("arguments") or entry.get("input")
            call = ToolCall(
                name=entry.get("name", ""),
                args=args if isinstance(args, dict) else {},
                status="called",
            )
            trajectory.append(call)
            if call_id:
                pending[str(call_id)] = call
        elif etype in ("tool_result", "toolResult", "function_response"):
            call_id = entry.get("id") or entry.get("call_id") or entry.get("tool_call_id") or ""
            output = entry.get("output")
            if output is None:
                output = entry.get("content") or entry.get("response")
            text = output if isinstance(output, str) else json.dumps(output, default=str)
            target = pending.pop(str(call_id), None) if call_id else None
            if target is None:
                # An unpaired result still carries useful diagnostics; append
                # it as a synthetic completed entry so the metrics see it.
                trajectory.append(
                    ToolCall(
                        name=entry.get("name", ""),
                        args={},
                        result=text,
                        status="error" if entry.get("is_error") else "completed",
                    )
                )
                errors.append(
                    f"trajectory tool_result without matching call (id={call_id!r})"
                )
                continue
            target.result = text
            target.status = "error" if entry.get("is_error") else "completed"
        elif etype == "message":
            usage = entry.get("usage")
            if isinstance(usage, dict):
                tokens = usage

    return [call.to_dict() for call in trajectory], tokens, errors


def _read_export_bundle(workspace: Path) -> tuple[str, str, list[str]]:
    """Locate and read the trajectory JSONL inside an ``export-trajectory`` bundle.

    The bundle is written under ``<workspace>/.openclaw/trajectory-exports/`` as
    documented in ``docs/openclaw/sessions.md``. There is exactly one export
    per run (we wipe sessions first), so a recursive glob suffices.

    Args:
        workspace: Workspace dir handed to ``oc sessions export-trajectory --workspace``.

    Returns:
        A ``(trajectory_jsonl, final_text, errors)`` tuple. ``final_text`` is
        the bundle's ``output.txt`` / ``output.md`` if present, otherwise the
        empty string.
    """
    errors: list[str] = []
    export_root = workspace / ".openclaw" / "trajectory-exports"
    if not export_root.exists():
        errors.append(f"export-trajectory bundle missing: {export_root}")
        return "", "", errors

    trajectory_files = sorted(export_root.rglob("trajectory*.jsonl"))
    trajectory_text = ""
    if trajectory_files:
        try:
            trajectory_text = trajectory_files[0].read_text()
        except OSError as exc:
            errors.append(f"failed to read {trajectory_files[0]}: {exc}")
    else:
        errors.append(f"no trajectory*.jsonl under {export_root}")

    output_text = ""
    for candidate in ("output.md", "output.txt", "final.txt"):
        for hit in export_root.rglob(candidate):
            try:
                output_text = hit.read_text()
            except OSError:
                continue
            break
        if output_text:
            break

    return trajectory_text, output_text, errors


@AGENTS.register("openclaw")
class OpenClawAgent(RulesMixin, AgentHarness):
    """OpenClaw CLI agent harness driving the local ``oc`` binary.

    The binary path is resolved from ``config.target`` (which defaults to the
    legacy ``AGENT_TARGET`` env when :meth:`AgentConfig.from_env` was used),
    falling back to ``~/bin/oc`` and then ``"oc"`` on ``$PATH``. Model /
    provider flow from ``config.model`` / ``config.provider`` via an
    ``oc models set <id>`` fragment prepended to the bash command — never
    hardcoded. Trajectory is exported through the official
    ``oc sessions export-trajectory`` command into a per-run temp workspace
    and parsed into the canonical :class:`ToolCall` list.

    Inherits :class:`RulesMixin` so the orchestrator can grant operator-brief
    text uniformly. The installed ``oc`` build today exposes no in-agent MCP
    or skills wiring, so :class:`McpMixin` / :class:`SkillsMixin` are *not*
    declared — capability negotiation would otherwise grant a binding the
    agent silently ignores.

    Args:
        config: Typed :class:`AgentConfig`; defaults are used when omitted.
        agent_name: ``oc`` agent profile (defaults to ``"operator"``).
    """

    def __init__(
        self, config: AgentConfig | None = None, *, agent_name: str = "operator"
    ) -> None:
        AgentHarness.__init__(self, config)
        self.agent_name = agent_name
        self.rules = self.config.capabilities.rules

    def _resolve_oc_bin(self) -> str:
        """Pick the ``oc`` binary path from config or fall back."""
        if self.config.target:
            return os.path.expanduser(self.config.target)
        candidate = os.path.expanduser("~/bin/oc")
        return candidate if os.path.exists(candidate) else "oc"

    def _execute(self, prompt: str) -> AgentResult:
        """Run ``oc agent --local`` and extract the canonical trajectory."""
        oc_bin = self._resolve_oc_bin()
        command = _build_local_command(self.config, prompt, self.agent_name, oc_bin)

        try:
            completed = subprocess.run(
                command,
                shell=True,  # noqa: S602 - bash needed for nvm; all values shlex.quoted
                executable="/bin/bash",
                capture_output=True,
                text=True,
                check=False,
                timeout=self.config.timeout_sec,
            )
        except subprocess.TimeoutExpired as exc:
            return AgentResult.errored(f"oc agent timed out after {exc.timeout}s")
        except OSError as exc:
            return AgentResult.errored(f"oc binary unavailable: {exc}")

        stdout_text = _strip_ansi(completed.stdout or "")
        errors: list[str] = []
        metadata: dict = {}

        if completed.returncode != 0:
            stderr = (completed.stderr or "").strip()
            errors.append(f"oc agent exited {completed.returncode}: {stderr or '<no stderr>'}")
            metadata["returncode"] = completed.returncode

        trajectory, tokens, bundle_output, export_errors = self._extract_trajectory(oc_bin)
        errors.extend(export_errors)

        # Prefer the bundle's clean output (output.md / output.txt / final.txt)
        # over the ansi-stripped bash stdout — the latter is full of `oc
        # --log-level debug` noise the judge would otherwise grade. Fall back
        # to stdout only when the bundle had no output file.
        output = bundle_output if bundle_output else stdout_text

        return AgentResult(
            output=output,
            trajectory=trajectory,
            tokens=tokens,
            errors=errors,
            metadata=metadata,
        )

    def _extract_trajectory(
        self, oc_bin: str
    ) -> tuple[list[dict], dict, str, list[str]]:
        """Run ``oc sessions`` + ``export-trajectory`` and parse the bundle.

        Returns:
            A ``(trajectory, tokens, output_text, errors)`` tuple. ``output_text``
            is the bundle's clean final output (``output.md`` / ``output.txt``
            / ``final.txt``) when present, else ``""``; the caller falls back
            to the ansi-stripped subprocess stdout when this is empty.
        """
        errors: list[str] = []
        try:
            sessions = run(
                [oc_bin, "sessions", "--agent", self.agent_name, "--json"],
                check=False,
                timeout=self.config.timeout_sec,
            )
        except SubprocessError as exc:
            errors.append(f"oc sessions failed: {exc}")
            return [], {}, "", errors
        except OSError as exc:
            errors.append(f"oc sessions: binary unavailable: {exc}")
            return [], {}, "", errors

        if sessions.returncode != 0:
            stderr = (sessions.stderr or "").strip()
            errors.append(
                f"oc sessions exited {sessions.returncode}: {stderr or '<no stderr>'}"
            )
            return [], {}, "", errors

        key = _pick_session_key(sessions.stdout or "")
        if key is None:
            errors.append("oc sessions returned no session key")
            return [], {}, "", errors

        with tempfile.TemporaryDirectory(prefix="oc-export-") as tmpdir:
            workspace = Path(tmpdir)
            try:
                export = run(
                    [
                        oc_bin,
                        "sessions",
                        "export-trajectory",
                        "--session-key",
                        key,
                        "--workspace",
                        str(workspace),
                        "--json",
                    ],
                    check=False,
                    timeout=self.config.timeout_sec,
                )
            except SubprocessError as exc:
                errors.append(f"oc export-trajectory failed: {exc}")
                return [], {}, "", errors
            except OSError as exc:
                errors.append(f"oc export-trajectory: binary unavailable: {exc}")
                return [], {}, "", errors

            if export.returncode != 0:
                stderr = (export.stderr or "").strip()
                errors.append(
                    f"oc export-trajectory exited {export.returncode}: "
                    f"{stderr or '<no stderr>'}"
                )
                return [], {}, "", errors

            trajectory_text, output_text, read_errors = _read_export_bundle(workspace)
            errors.extend(read_errors)
            if not trajectory_text:
                return [], {}, output_text, errors

            trajectory, tokens, parse_errors = parse_trajectory_export(trajectory_text)
            errors.extend(parse_errors)
            return trajectory, tokens, output_text, errors


def _pick_session_key(sessions_json: str) -> str | None:
    """Return the single session key from ``oc sessions --json`` output, or ``None``.

    The output may be a list of rows or a wrapper dict with a ``sessions``
    list (per ``docs/openclaw/sessions.md``). Because the run wiped the
    sessions dir first, exactly one row is expected; if more than one is
    present the first is taken (with a debug log).

    Args:
        sessions_json: Raw stdout from ``oc sessions --agent <name> --json``.

    Returns:
        The ``key`` field of the chosen session, or ``None`` if parsing
        failed or no sessions were returned.
    """
    try:
        data = json.loads(sessions_json)
    except json.JSONDecodeError:
        return None
    rows = data.get("sessions") if isinstance(data, dict) else data
    if not isinstance(rows, list) or not rows:
        return None
    if len(rows) > 1:
        _log.debug("oc sessions returned %d rows; using the first", len(rows))
    first = rows[0]
    if not isinstance(first, dict):
        return None
    key = first.get("key")
    return key if isinstance(key, str) and key else None
