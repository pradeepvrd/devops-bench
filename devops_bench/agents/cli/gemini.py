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

"""Gemini CLI agent harness (the ``gemini`` binary with the GKE MCP extension)."""

from __future__ import annotations

import glob
import json
import os
import time

from devops_bench.agents.base import AGENTS, AgentHarness
from devops_bench.agents.cli.openclaw import run_openclaw_agent, run_openclaw_agent_local
from devops_bench.core import SubprocessError, first_env, get_bool, get_env, get_logger
from devops_bench.core.subprocess import run

__all__ = [
    "GeminiCliAgent",
    "parse_gemini_cli_output",
    "extract_trajectory_from_session",
    "run_cli_agent",
]

_log = get_logger("agents.cli.gemini")

# GKE MCP tools pre-approved so the CLI does not block on interactive
# confirmation prompts in headless mode.
_ALLOWED_MCP_TOOLS = (
    "mcp_gke_list_clusters",
    "mcp_gke_get_cluster",
    "mcp_gke_generate_manifest",
    "mcp_gke_giq_generate_manifest",
    "mcp_gke_query_logs",
    "mcp_gke_get_log_schema",
    "mcp_gke_get_kubeconfig",
    "mcp_gke_list_namespaces",
)


def _extract_json_object(text: str) -> dict | None:
    """Return the last top-level JSON object embedded in ``text``, or ``None``.

    The Gemini CLI interleaves its JSON payload with plain log lines that may
    themselves contain braces. A greedy ``{.*}`` match would span from the first
    ``{`` to the last ``}`` across unrelated lines and fail to parse. Instead this
    scans for balanced top-level ``{...}`` spans (brace-counting, skipping braces
    inside JSON strings) and returns the last one that parses as a dict.

    Args:
        text: Raw CLI stdout, possibly with log noise around the JSON.

    Returns:
        The parsed JSON object, or ``None`` when no balanced object parses.
    """
    result: dict | None = None
    depth = 0
    start = -1
    in_string = False
    escaped = False
    for i, ch in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}" and depth > 0:
            depth -= 1
            if depth == 0 and start != -1:
                try:
                    candidate = json.loads(text[start : i + 1])
                except json.JSONDecodeError:
                    candidate = None
                if isinstance(candidate, dict):
                    result = candidate
                start = -1
    return result


def parse_gemini_cli_output(raw_output: str) -> dict:
    """Parse the JSON output emitted by the Gemini CLI, tolerating log noise.

    Args:
        raw_output: Raw stdout from a ``gemini -o json`` run.

    Returns:
        A dict with ``output`` (response text), ``tokens``, ``tools``, and
        ``session_id`` (``None`` when absent). Parse failures fall back to the
        raw output with empty stats.
    """
    output = raw_output
    tokens: dict = {}
    tools: dict = {}
    session_id = None

    try:
        data = _extract_json_object(raw_output)
        if data is not None:
            output = data.get("response", raw_output)
            stats = data.get("stats", {})
            session_id = data.get("session_id")

            models_stats = stats.get("models", {})
            for model_data in models_stats.values():
                tokens = model_data.get("tokens", {})
                break

            tools = stats.get("tools", {})
    except Exception as exc:  # noqa: BLE001 - log noise can take many shapes; never fail the run
        _log.warning("Failed to parse JSON output from Gemini CLI: %s", exc)

    return {"output": output, "tokens": tokens, "tools": tools, "session_id": session_id}


def extract_trajectory_from_session(session_id: str) -> dict:
    """Locate and parse the session file for ``session_id`` to extract trajectory.

    Args:
        session_id: Session id reported by the Gemini CLI.

    Returns:
        A dict with ``trajectory`` (list of tool-call dicts) and ``skills``
        (deduplicated skill names referenced via ``read_file``). Both are empty
        when no session file is found.
    """
    trajectory: list = []
    base_dir = os.path.expanduser("~/.gemini/tmp/devops-bench/chats")
    if not os.path.exists(base_dir):
        _log.warning("Session directory not found: %s", base_dir)
        return {"trajectory": [], "skills": []}

    short_id = session_id.split("-")[0] if "-" in session_id else session_id
    # Escape the id so glob metacharacters in a session id are matched literally.
    escaped_id = glob.escape(short_id)
    pattern = os.path.join(base_dir, f"session-*-{escaped_id}.jsonl")
    files = glob.glob(pattern)

    if not files:
        pattern_rec = os.path.join(base_dir, "**", f"*{escaped_id}.jsonl")
        files = glob.glob(pattern_rec, recursive=True)

    if not files:
        _log.warning("No session file found for session_id: %s", session_id)
        return {"trajectory": [], "skills": []}

    session_file = files[0]
    _log.debug("Parsing session file: %s", session_file)

    referenced_skills: list = []
    try:
        with open(session_file) as f:
            for line in f:
                try:
                    data = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if data.get("type") != "gemini":
                    continue
                for call in data.get("toolCalls", []):
                    name = call.get("name")
                    args = call.get("args")
                    trajectory.append({"name": name, "args": args, "status": call.get("status")})

                    # Filter for skills referenced via read_file.
                    if name == "read_file" and isinstance(args, dict):
                        file_path = args.get("file_path", "")
                        if "skills" in file_path or file_path.endswith("SKILL.md"):
                            parts = file_path.split("/")
                            if "skills" in parts:
                                idx = parts.index("skills")
                                if idx + 1 < len(parts):
                                    referenced_skills.append(parts[idx + 1])
                            elif file_path.endswith("SKILL.md") and len(parts) >= 2:
                                # No ``skills`` dir (e.g. /plugin/my-skill/SKILL.md):
                                # the skill name is the SKILL.md's parent folder.
                                referenced_skills.append(parts[-2])
    except OSError as exc:
        _log.warning("Failed to read session file: %s", exc)

    return {"trajectory": trajectory, "skills": list(set(referenced_skills))}


def _gemini_env() -> dict[str, str]:
    """Build the env overlay that makes the Gemini CLI run model-agnostic.

    Maps the benchmark's neutral ``AGENT_*`` config onto the vars the Gemini CLI
    expects (``GOOGLE_API_KEY``/``GEMINI_API_KEY``/``GEMINI_MODEL``) and disables
    OTLP telemetry exporters that otherwise hang on broken endpoints. The model is
    never hardcoded; it flows from ``AGENT_MODEL``.

    Returns:
        A mapping suitable for ``core.subprocess.run``'s ``extra_env``.
    """
    overlay: dict[str, str] = {
        "OTEL_TRACES_EXPORTER": "none",
        "OTEL_METRICS_EXPORTER": "none",
        "OTEL_LOGS_EXPORTER": "none",
        "OTEL_SDK_DISABLED": "true",
    }
    api_key = get_env("AGENT_API_KEY")
    if api_key:
        overlay["GOOGLE_API_KEY"] = api_key
        overlay["GEMINI_API_KEY"] = api_key
    model = get_env("AGENT_MODEL")
    if model:
        overlay["GEMINI_MODEL"] = model
    return overlay


def run_cli_agent(
    agent_target: str,
    prompt: str,
    context: dict | None,
    bench_use_mcp: bool = True,
    system_instruction: str | None = None,
) -> dict:
    """Run an external CLI agent binary and collect its trajectory.

    Dispatches by binary name, checking ``gemini`` first (so a gemini path
    containing the naive ``oc`` substring is not misrouted): a ``gemini`` target
    is invoked directly with JSON output and (optionally) pre-approved GKE MCP
    tools; an ``openclaw``/``oc`` target is delegated to the OpenClaw runner
    (local when ``OPENCLAW_LOCAL=true``, otherwise over SSH); any other (generic
    ``"binary"``) target is run with the goal/context fed as JSON on stdin.

    Args:
        agent_target: Path to the agent binary (``~`` expanded).
        prompt: Task prompt for the agent.
        context: Platform-agnostic context; passed through to OpenClaw.
        bench_use_mcp: For Gemini, pre-approve the GKE MCP tools; when ``False``
            the CLI is run with extensions disabled (``-e none``).
        system_instruction: Optional instruction appended to the prompt.

    Returns:
        The standardized result dict (``output``, ``latency``, ``tokens``,
        ``tools``, ``trajectory``, ``skills``).
    """
    from deepeval.tracing import observe

    @observe()
    def _run() -> dict:
        target = os.path.expanduser(agent_target)
        full_prompt = prompt
        if system_instruction:
            full_prompt = f"{prompt}\n\nInstructions: {system_instruction}"

        args = [target]
        stdin_data: str | None = None
        # Dispatch by binary name. Match legacy gcli.py precedence: check
        # "gemini" FIRST so a gemini path that happens to contain the naive "oc"
        # substring (e.g. /usr/local/bin/gemini) is not misrouted to OpenClaw.
        if "gemini" in target:
            args.extend(["-o", "json", "--skip-trust"])
            if bench_use_mcp:
                for tool in _ALLOWED_MCP_TOOLS:
                    args.extend(["--allowed-tools", tool])
            else:
                args.extend(["-e", "none"])
            args.extend(["-p", full_prompt])
        elif "openclaw" in target or "oc" in target:
            if get_bool("OPENCLAW_LOCAL"):
                return run_openclaw_agent_local(full_prompt, context, agent_name="operator")
            return run_openclaw_agent(full_prompt, context, agent_name="operator")
        else:
            # Generic "binary" agent: legacy gcli.py passed neither -p nor flags
            # and fed the goal/context as JSON on stdin. Preserve that contract.
            stdin_data = json.dumps({"goal": full_prompt, "context": context})

        start_time = time.time()
        try:
            result = run(args, extra_env=_gemini_env(), input=stdin_data)
        except (SubprocessError, OSError) as exc:
            # OSError covers a missing/non-executable binary, which
            # core.subprocess.run does not wrap.
            detail = getattr(exc, "stderr", None) or exc
            return {
                "output": f"Error: {detail}",
                "latency": time.time() - start_time,
                "tokens": {},
                "tools": {},
                "trajectory": [],
                "skills": [],
            }

        latency = time.time() - start_time
        output = result.stdout
        tokens: dict = {}
        tools: dict = {}
        trajectory: list = []
        skills: list = []

        if "-o" in args and "json" in args:
            parsed = parse_gemini_cli_output(output)
            output = parsed["output"]
            tokens = parsed["tokens"]
            tools = parsed["tools"]
            session_id = parsed.get("session_id")
            if session_id:
                res = extract_trajectory_from_session(session_id)
                trajectory = res.get("trajectory", [])
                skills = res.get("skills", [])

        return {
            "output": output,
            "latency": latency,
            "tokens": tokens,
            "tools": tools,
            "trajectory": trajectory,
            "skills": skills,
        }

    return _run()


@AGENTS.register("gemini")
class GeminiCliAgent(AgentHarness):
    """Gemini CLI agent harness driving the ``gemini`` binary.

    The binary path is resolved with precedence ``AGENT_TARGET`` → ``GEMINI_PATH``
    → ``"gemini"`` on ``PATH``. Provider and model selection flow from
    ``AGENT_PROVIDER``/``AGENT_MODEL`` via the env overlay, never hardcoded.

    Args:
        agent_target: Path to the ``gemini`` binary; when ``None`` it is resolved
            from ``AGENT_TARGET``/``GEMINI_PATH`` (in that order), then ``"gemini"``.
        bench_use_mcp: Pre-approve the GKE MCP tools (``True``) or disable
            extensions (``False``).
    """

    def __init__(self, agent_target: str | None = None, bench_use_mcp: bool = True) -> None:
        self.agent_target = agent_target or first_env(
            "AGENT_TARGET", "GEMINI_PATH", default="gemini"
        )
        self.bench_use_mcp = bench_use_mcp

    def run(self, prompt: str, context: dict | None = None) -> dict:
        """Run the Gemini CLI agent against ``prompt``."""
        return run_cli_agent(
            self.agent_target,
            prompt,
            context,
            bench_use_mcp=self.bench_use_mcp,
        )
