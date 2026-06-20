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

"""API/MCP agent harness driving the shared :func:`run_tool_loop` primitive.

The :class:`ApiAgent` subclasses :class:`AgentHarness` and overrides
``_execute`` to:

1. Build a neutral :class:`LLMClient` via :func:`devops_bench.models.get_model`
   with **explicit** ``provider``/``model`` args sourced from ``AgentConfig``
   (no env-smuggling — the agent never reads ``BENCH_USE_MCP``).
2. Discover skill tools (when ``config.skills_paths`` is set) and, in parallel,
   open an MCP session (when ``config.target`` is set). Skills and MCP are
   **independently controlled**: an agent may have skills without MCP or MCP
   without skills.
3. Format tools via ``client.format_tools(...)`` (caller-formats-tools) and
   pass them — pre-formatted — to :func:`run_tool_loop`.
4. Provide a ``dispatch`` closure that routes each tool call to either a skill
   file read or the MCP session, wrapping every call in its own try/except so
   one tool failure lands on the trajectory/errors rather than aborting the
   loop (``run_tool_loop`` propagates dispatch errors by design).
5. Fold :class:`LoopResult` into an :class:`AgentResult` whose ``trajectory``
   is a list of canonical :class:`ToolCall` entries; populate ``output`` from
   ``final_text``, ``tokens`` / ``latency`` / ``errors`` / ``metadata``.
"""

from __future__ import annotations

import asyncio
from typing import Any

from devops_bench.agents.api.mcp import MCPClient, extract_tool_text
from devops_bench.agents.api.skills import (
    SkillToolInfo,
    discover_skill_tools,
    read_skill_file,
)
from devops_bench.agents.base import AGENTS, AgentHarness
from devops_bench.agents.result import AgentResult, ToolCall
from devops_bench.core import get_logger
from devops_bench.models import LLMClient, get_model
from devops_bench.models.loop import LoopResult, run_tool_loop

__all__ = ["ApiAgent", "fold_trajectory", "extract_tokens"]

_log = get_logger("agents.api.agent")

# Default safety cap on agent turns; overridable via ``AgentConfig.max_turns``.
# Set high because API agents legitimately take many tool-use turns — it only
# guards against a model that never stops requesting tools.
_DEFAULT_MAX_TURNS = 50


def fold_trajectory(contents: list[dict]) -> list[dict]:
    """Fold a :class:`LoopResult.contents` history into canonical trajectory entries.

    For every ``{role: assistant, tool_calls: [...]}`` message, each entry in
    its ``tool_calls`` list is paired with the matching adjacent
    ``{role: tool, ...}`` result and emitted as one :class:`ToolCall` entry.
    Pairing is by ``tool_call_id`` (echoed on the tool message); a call with no
    matching result is emitted as ``status="called"`` with ``result=None``.

    Messages with ``role == "user"`` or ``role == "assistant"`` without
    ``tool_calls`` are not represented in the trajectory — the conversation's
    final assistant text already flows out via :attr:`AgentResult.output`.

    Args:
        contents: The conversation history produced by :func:`run_tool_loop`
            (neutral message shape per CONVENTIONS §5).

    Returns:
        A list of ``ToolCall.to_dict()`` mappings, one per tool call the model
        issued, in the order issued.
    """
    # Pre-build call-id → (text, is_error) map so an out-of-order or absent
    # result still leaves the call as ``status="called"``/``result=None`` rather
    # than crashing on a lookup.
    results_by_id: dict[str, tuple[str, bool]] = {}
    for msg in contents:
        if msg.get("role") != "tool":
            continue
        call_id = msg.get("tool_call_id")
        if call_id is None:
            continue
        text = msg.get("content")
        text_str = text if isinstance(text, str) else "" if text is None else str(text)
        is_error = isinstance(text, str) and text.startswith("Error: ")
        results_by_id[str(call_id)] = (text_str, is_error)

    trajectory: list[ToolCall] = []
    for msg in contents:
        if msg.get("role") != "assistant":
            continue
        tool_calls = msg.get("tool_calls") or []
        for call in tool_calls:
            name = call.get("name", "")
            args = call.get("args")
            call_id = call.get("id")
            entry = ToolCall(
                name=name,
                args=args if isinstance(args, dict) else {},
                status="called",
            )
            if call_id is not None:
                hit = results_by_id.get(str(call_id))
                if hit is not None:
                    text, is_error = hit
                    entry.result = text
                    entry.status = "error" if is_error else "completed"
            trajectory.append(entry)

    return [entry.to_dict() for entry in trajectory]


def extract_tokens(response: Any) -> dict:
    """Pull provider token usage off the final raw response.

    Accepts either ``usage_metadata`` (Google-style) or ``usage`` (Anthropic /
    OpenAI-style). Missing fields default to ``0``. When neither attribute is
    present, returns an empty dict so :attr:`AgentResult.tokens` stays uniform.

    Args:
        response: The last raw provider response from
            :attr:`LoopResult.response`, or ``None``.

    Returns:
        A ``{"prompt_tokens", "candidates_tokens", "total_tokens"}`` dict, or
        ``{}`` when no usage is reported.
    """
    if response is None:
        return {}
    usage = getattr(response, "usage_metadata", None) or getattr(response, "usage", None)
    if usage is None:
        return {}
    return {
        "prompt_tokens": getattr(usage, "prompt_token_count", 0),
        "candidates_tokens": getattr(usage, "candidates_token_count", 0),
        "total_tokens": getattr(usage, "total_token_count", 0),
    }


def _build_dispatch(
    mcp_client: MCPClient | None,
    skill_resources: dict[str, str],
    errors: list[str],
):
    """Build the dispatcher passed to :func:`run_tool_loop`.

    Wraps each tool call in its own ``try/except`` because ``run_tool_loop``
    propagates dispatch errors by design — letting a single tool failure abort
    the whole run would be wrong for a benchmark agent. Failures are recorded
    on ``errors`` and returned as the tool result text so the model can react
    on the next turn.

    Args:
        mcp_client: Active :class:`MCPClient`, or ``None`` when MCP is off.
        skill_resources: Map of skill tool name to local file path; populated
            by :func:`devops_bench.agents.api.skills.discover_skill_tools`.
        errors: Errors list to mutate when a dispatch raises.

    Returns:
        An async ``(name, args, call_id) -> str`` callable matching
        :data:`devops_bench.models.loop.ToolDispatcher`.
    """

    async def dispatch(name: str, args: Any, call_id: str | None) -> str:
        try:
            # Skill tools take priority — they are advertised in the same tool
            # list but are served locally without round-tripping the MCP server.
            if name in skill_resources:
                file_path = skill_resources[name]
                _log.info("Calling skill tool %s for file %s", name, file_path)
                return await asyncio.to_thread(read_skill_file, file_path)
            if mcp_client is None:
                msg = (
                    f"Error: tool {name!r} requested but no MCP server is "
                    "configured for this agent."
                )
                errors.append(msg)
                return msg
            arg_dict = args if isinstance(args, dict) else {}
            tool_result = await mcp_client.call_tool(name, arg_dict)
            return extract_tool_text(tool_result)
        except Exception as exc:  # noqa: BLE001 - one tool failure must not abort the run
            msg = f"Error calling tool {name}: {exc}"
            _log.warning(msg)
            errors.append(msg)
            return f"Error: {exc}"

    return dispatch


async def _gather_tools(
    mcp_client: MCPClient | None,
    skill_tools: list[SkillToolInfo],
) -> list[Any]:
    """Return the combined MCP + skill tool list passed to ``format_tools``.

    Args:
        mcp_client: Active MCP client, or ``None`` when MCP is off.
        skill_tools: Skill tool descriptors from
            :func:`discover_skill_tools`.

    Returns:
        A list of tool objects (MCP-native or :class:`SkillToolInfo`) in MCP
        order followed by skill order. Both are duck-typed (``name``,
        ``description``, ``inputSchema``) so adapters' ``format_tools`` handles
        them uniformly.
    """
    tools: list[Any] = []
    if mcp_client is not None:
        tools_result = await mcp_client.list_tools()
        tools.extend(tools_result.tools)
    tools.extend(skill_tools)
    return tools


async def _run_async(
    client: LLMClient,
    prompt: str,
    mcp_server_path: str | None,
    skills_paths: tuple[str, ...],
    max_turns: int,
) -> tuple[LoopResult, list[str], list[str]]:
    """Drive the tool-use loop and return its ``(LoopResult, errors, skills)``.

    Opens an MCP session when ``mcp_server_path`` is set and discovers local
    skills when ``skills_paths`` is non-empty — the two are independent. The
    tool list is formatted by the caller (per CONVENTIONS §6: caller-formats-
    tools) and passed to :func:`run_tool_loop` pre-formatted.

    Args:
        client: Neutral LLM client.
        prompt: Task prompt seeding the loop.
        mcp_server_path: Command launching the MCP server, or ``None`` to skip
            MCP entirely.
        skills_paths: Filesystem locations to discover local skills under.
        max_turns: Safety cap on turns.

    Returns:
        A ``(loop_result, errors, skill_names)`` tuple. ``errors`` carries any
        per-tool dispatch failures recorded by the dispatcher.
    """
    errors: list[str] = []
    skill_tools, skill_resources, skill_names = await asyncio.to_thread(
        discover_skill_tools, skills_paths
    )

    if not mcp_server_path:
        formatted = client.format_tools(skill_tools)
        dispatch = _build_dispatch(None, skill_resources, errors)
        loop_result = await run_tool_loop(
            client=client,
            goal=prompt,
            tools=formatted,
            system_instruction=None,
            dispatch=dispatch,
            max_turns=max_turns,
        )
        return loop_result, errors, skill_names

    async with MCPClient(mcp_server_path) as mcp_client:
        tools = await _gather_tools(mcp_client, skill_tools)
        formatted = client.format_tools(tools)
        dispatch = _build_dispatch(mcp_client, skill_resources, errors)
        loop_result = await run_tool_loop(
            client=client,
            goal=prompt,
            tools=formatted,
            system_instruction=None,
            dispatch=dispatch,
            max_turns=max_turns,
        )
        return loop_result, errors, skill_names


@AGENTS.register("api")
class ApiAgent(AgentHarness):
    """API agent harness driving a model-agnostic MCP tool-use loop.

    Provider, model, and MCP server command all flow from
    :class:`~devops_bench.agents.config.AgentConfig` — no environment reads
    happen inside this class. Capability gates:

    * **MCP on/off** is driven by ``config.target`` (the MCP server command).
      No ``BENCH_USE_MCP`` env read.
    * **Skills on/off** is driven by ``config.skills_paths`` independently of
      MCP — an agent may run with skills only, MCP only, both, or neither.

    The execute path opens the MCP session (when configured), discovers
    skills, hands the *pre-formatted* tool list to :func:`run_tool_loop`, and
    folds the resulting conversation history into canonical
    :class:`~devops_bench.agents.result.ToolCall` trajectory entries via
    :func:`fold_trajectory`.
    """

    def _execute(self, prompt: str) -> AgentResult:
        """Build the LLM client, drive the loop, and assemble an AgentResult.

        Args:
            prompt: Task prompt handed to the agent.

        Returns:
            An :class:`AgentResult` whose ``trajectory`` is a list of canonical
            :class:`ToolCall` entries, ``output`` is :attr:`LoopResult.final_text`,
            and ``tokens`` / ``latency`` carry the loop's accumulated values.
        """
        llm_client = get_model(self.config.provider, self.config.model)
        max_turns = self.config.max_turns or _DEFAULT_MAX_TURNS

        try:
            loop_result, dispatch_errors, skill_names = asyncio.run(
                _run_async(
                    llm_client,
                    prompt,
                    self.config.target,
                    self.config.skills_paths,
                    max_turns,
                )
            )
        except ValueError as exc:
            # E.g. empty MCP server command; surface as a clean errored result
            # rather than letting it bubble through the base safety net.
            return AgentResult.errored(str(exc))

        trajectory = fold_trajectory(loop_result.contents)
        tokens = extract_tokens(loop_result.response)
        metadata: dict[str, Any] = {
            "tools_used": sorted(loop_result.tools_used),
        }
        if skill_names:
            metadata["skills_loaded"] = list(skill_names)

        return AgentResult(
            output=loop_result.final_text,
            trajectory=trajectory,
            tokens=tokens,
            latency=loop_result.latency,
            errors=list(dispatch_errors),
            metadata=metadata,
        )
