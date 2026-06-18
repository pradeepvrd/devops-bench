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

"""Model-agnostic API agent: an MCP tool-use loop driven by a neutral LLMClient."""

from __future__ import annotations

import asyncio
import glob
import os
import re
import time
from typing import Any

from devops_bench.agents.api.mcp import MCPClient
from devops_bench.agents.base import AGENTS, AgentHarness
from devops_bench.core import get_bool, get_env, get_int, get_logger
from devops_bench.models import LLMClient, get_model

__all__ = [
    "ApiAgent",
    "run_api_agent",
    "process_query",
    "call_mcp_tool",
    "parse_skill_md",
]

_log = get_logger("agents.api.loop")

# Directory of local skill files exposed to the agent as synthetic tools.
_SKILLS_DIR = "third_party/gke-mcp/skills"

# Default safety cap on agent turns, overridable via ``AGENT_MAX_TURNS``. Set high
# because API agents legitimately take many tool-use turns; it only guards against
# a model that never stops requesting tools.
_DEFAULT_MAX_TURNS = 50


async def call_mcp_tool(session: Any, name: str, args: dict) -> Any:
    """Call an MCP tool and trace it with DeepEval.

    Args:
        session: An MCP client session exposing ``call_tool``.
        name: Tool name to invoke.
        args: Keyword arguments for the tool.

    Returns:
        The raw tool-call result.
    """
    from deepeval.tracing import observe

    @observe(span_type="TOOL")
    async def _call() -> Any:
        return await session.call_tool(name, arguments=args)

    return await _call()


def parse_skill_md(file_path: str) -> tuple[str | None, str | None, str | None]:
    """Parse a ``SKILL.md`` file's YAML frontmatter.

    Args:
        file_path: Path to a skill markdown file.

    Returns:
        A ``(name, description, content)`` tuple. Each element is ``None`` when
        the file is unreadable or the corresponding frontmatter field is absent.
    """
    try:
        with open(file_path) as f:
            content = f.read()
        match = re.search(r"^---\s*\n(.*?)\n---\s*\n", content, re.DOTALL | re.MULTILINE)
        if match:
            frontmatter = match.group(1)
            name_match = re.search(r"^name:\s*(.*?)\s*$", frontmatter, re.MULTILINE)
            desc_match = re.search(r"^description:\s*(.*?)\s*$", frontmatter, re.MULTILINE)

            name = name_match.group(1).strip().strip('"').strip("'") if name_match else None
            description = (
                desc_match.group(1).strip().strip('"').strip("'") if desc_match else None
            )
            return name, description, content
    except OSError as exc:
        _log.warning("Error parsing skill file %s: %s", file_path, exc)
    return None, None, None


class _ToolInfo:
    """Lightweight duck-typed stand-in for an MCP tool (used for local skills)."""

    def __init__(self, name: str, description: str, inputSchema: Any = None) -> None:  # noqa: N803 - matches MCP tool attr
        self.name = name
        self.description = description
        self.inputSchema = inputSchema


def _extract_tool_text(tool_result: Any) -> str:
    """Aggregate the text of every content block in an MCP tool result.

    Args:
        tool_result: The raw result returned by ``MCPClient.call_tool``.

    Returns:
        The newline-joined text of all blocks exposing a ``text`` attribute. If
        the result has no ``content`` blocks (or none carry text), the result is
        stringified instead.
    """
    content = getattr(tool_result, "content", None)
    if content:
        texts = [block.text for block in content if hasattr(block, "text")]
        if texts:
            return "\n".join(texts)
    return str(tool_result)


async def process_query(
    llm_client: LLMClient,
    contents: list[dict],
    tools: Any,
    system_instruction: str | None,
    mcp_client: MCPClient | None,
) -> tuple[Any, list[dict], float]:
    """Run a single turn: generate content and resolve any tool calls.

    Appends the assistant message and any tool results to ``contents`` in place.

    Args:
        llm_client: Neutral LLM client.
        contents: Running conversation history (mutated in place).
        tools: Provider-formatted tools from :meth:`LLMClient.format_tools`.
        system_instruction: Optional system prompt.
        mcp_client: MCP client for tool execution, or ``None`` when MCP is off.

    Returns:
        A ``(response, contents, duration)`` tuple where ``duration`` is the
        seconds spent in :meth:`LLMClient.generate_content`.
    """
    start_time = time.time()
    response = await llm_client.generate_content(contents, tools, system_instruction)
    duration = time.time() - start_time

    text_content = llm_client.get_text_content(response)
    function_calls = llm_client.extract_function_calls(response)

    assistant_message: dict[str, Any] = {"role": "assistant", "content": text_content}
    if function_calls:
        assistant_message["tool_calls"] = function_calls
    contents.append(assistant_message)

    if not function_calls:
        return response, contents, duration

    for function_call in function_calls:
        name = function_call["name"]
        args = function_call["args"]
        call_id = function_call.get("id")

        try:
            skill_resources = getattr(mcp_client, "skill_resources", {}) if mcp_client else {}
            if name in skill_resources:
                file_path = skill_resources[name]
                _log.info("Calling skill tool %s for file %s", name, file_path)
                try:
                    with open(file_path) as f:
                        result_text = f.read()
                except OSError as exc:
                    result_text = f"Error reading skill file {file_path}: {exc}"
            elif mcp_client is None:
                result_text = "Error: MCP client is not initialized; no tools are available."
            else:
                tool_result = await mcp_client.call_tool(name, args)
                result_text = _extract_tool_text(tool_result)

            contents.append(
                {"role": "tool", "tool_call_id": call_id, "name": name, "content": result_text}
            )
        except Exception as exc:  # noqa: BLE001 - a tool failure must not abort the loop
            _log.warning("Error calling tool %s: %s", name, exc)
            contents.append(
                {
                    "role": "tool",
                    "tool_call_id": call_id,
                    "name": name,
                    "content": f"Error: {exc}",
                }
            )

    return response, contents, duration


def _build_trajectory(contents: list[dict]) -> list[dict]:
    """Build a detailed trajectory from the conversation history.

    Args:
        contents: The full conversation history.

    Returns:
        A list of typed trajectory entries (``user_input``, ``agent_response``,
        ``tool_output``).
    """
    trajectory: list[dict] = []
    for msg in contents:
        role = msg["role"]
        if role == "user":
            trajectory.append({"type": "user_input", "content": msg["content"]})
        elif role == "assistant":
            trajectory.append(
                {
                    "type": "agent_response",
                    "content": msg.get("content", ""),
                    "tool_calls": msg.get("tool_calls", []),
                }
            )
        elif role == "tool":
            trajectory.append(
                {"type": "tool_output", "name": msg.get("name"), "content": msg.get("content")}
            )
    return trajectory


def _build_result(
    llm_client: LLMClient,
    response: Any,
    contents: list[dict],
    total_latency: float,
    tools_used: set[str],
    skills: list[str] | None,
) -> dict:
    """Assemble the standardized result dict from the final loop state.

    Args:
        llm_client: Neutral LLM client (used to extract the final text).
        response: The last raw model response.
        contents: The full conversation history.
        total_latency: Accumulated generation latency in seconds.
        tools_used: Names of tools the model requested.
        skills: Names of local skills exposed as tools.

    Returns:
        The standardized result dict (``output``, ``latency``, ``tokens``,
        ``tools``, ``trajectory``, ``skills``).
    """
    actual_output = llm_client.get_text_content(response)
    usage = getattr(response, "usage_metadata", None) or getattr(response, "usage", None)
    return {
        "output": actual_output,
        "latency": total_latency,
        "tokens": {
            "prompt_tokens": getattr(usage, "prompt_token_count", 0),
            "candidates_tokens": getattr(usage, "candidates_token_count", 0),
            "total_tokens": getattr(usage, "total_token_count", 0),
        }
        if usage
        else None,
        "tools": list(tools_used),
        "trajectory": _build_trajectory(contents),
        "skills": skills or [],
    }


async def _run_agent_loop(
    goal: str,
    tools: Any,
    mcp_client: MCPClient | None,
    llm_client: LLMClient,
    skills: list[str] | None = None,
    system_instruction: str | None = None,
    max_turns: int | None = None,
) -> dict:
    """Drive the agent until the model stops requesting tools or the cap is hit.

    Args:
        goal: The task prompt.
        tools: MCP tools (and synthetic skill tools) to advertise.
        mcp_client: MCP client for tool execution, or ``None`` when MCP is off.
        llm_client: Neutral LLM client.
        skills: Names of local skills exposed as tools (for the result dict).
        system_instruction: Optional system prompt.
        max_turns: Safety cap on turns; when ``None`` it is read from
            ``AGENT_MAX_TURNS`` (default :data:`_DEFAULT_MAX_TURNS`). Reaching the
            cap ends the loop with a warning rather than looping forever.

    Returns:
        The standardized result dict (``output``, ``latency``, ``tokens``,
        ``tools``, ``trajectory``, ``skills``).
    """
    if max_turns is None:
        max_turns = get_int("AGENT_MAX_TURNS", _DEFAULT_MAX_TURNS)

    total_latency = 0.0
    formatted_tools = llm_client.format_tools(tools)

    contents: list[dict] = [{"role": "user", "content": goal}]
    tools_used: set[str] = set()
    response: Any = None

    for turn in range(max_turns):
        _log.debug("--- Turn %d ---", turn + 1)
        response, contents, duration = await process_query(
            llm_client, contents, formatted_tools, system_instruction, mcp_client
        )
        total_latency += duration

        function_calls = llm_client.extract_function_calls(response)

        if not function_calls:
            _log.debug("No more function calls. Agent finished.")
            return _build_result(
                llm_client, response, contents, total_latency, tools_used, skills
            )

        for fc in function_calls:
            tools_used.add(fc["name"])
    else:
        _log.warning("API agent stopped after reaching the turn limit (%d)", max_turns)

    return _build_result(llm_client, response, contents, total_latency, tools_used, skills)


async def run_api_agent(
    goal: str,
    mcp_server_path: str | None,
    llm_client: LLMClient,
    bench_use_mcp: bool = True,
    system_instruction: str | None = None,
) -> dict:
    """Run the API agent, optionally connecting to an MCP server.

    When ``bench_use_mcp`` is set, connects to the MCP server at
    ``mcp_server_path``, discovers its tools, and additionally exposes any local
    skills under ``third_party/gke-mcp/skills`` as synthetic tools. Otherwise the
    loop runs with no tools.

    Args:
        goal: The task prompt.
        mcp_server_path: Command launching the MCP server (used when MCP is on).
        llm_client: Neutral LLM client built via the models layer.
        bench_use_mcp: Connect to the MCP server and expose its tools.
        system_instruction: Optional system prompt.

    Returns:
        The standardized result dict (``output``, ``latency``, ``tokens``,
        ``tools``, ``trajectory``, ``skills``).
    """
    from deepeval.tracing import observe

    @observe(span_type="LLM")
    async def _run() -> dict:
        if not bench_use_mcp:
            _log.info("Running without MCP tools.")
            return await _run_agent_loop(
                goal, [], None, llm_client, skills=[], system_instruction=system_instruction
            )

        async with MCPClient(mcp_server_path) as mcp_client:
            tools_result = await mcp_client.list_tools()
            tools = list(tools_result.tools)

            # Load local skills from the gke-mcp repo and expose them as tools.
            mcp_client.skill_resources = {}
            loaded_skills: list[str] = []
            if os.path.exists(_SKILLS_DIR):
                skill_files = glob.glob(
                    os.path.join(_SKILLS_DIR, "**", "SKILL.md"), recursive=True
                )
                for file_path in skill_files:
                    skill_name, description, _ = parse_skill_md(file_path)
                    if skill_name:
                        normalized_name = "skill_" + skill_name.replace("-", "_")
                        tools.append(
                            _ToolInfo(
                                name=normalized_name,
                                description=description or f"Exposes skill: {skill_name}",
                            )
                        )
                        mcp_client.skill_resources[normalized_name] = file_path
                        loaded_skills.append(skill_name)
                        _log.info(
                            "Loaded local skill as tool: %s -> %s", normalized_name, file_path
                        )
            else:
                _log.warning("Skills directory not found: %s", _SKILLS_DIR)

            return await _run_agent_loop(
                goal,
                tools,
                mcp_client,
                llm_client,
                skills=loaded_skills,
                system_instruction=system_instruction,
            )

    return await _run()


@AGENTS.register("api")
class ApiAgent(AgentHarness):
    """API agent harness driving a model-agnostic MCP tool-use loop.

    Provider and model selection flow from ``AGENT_PROVIDER``/``AGENT_MODEL`` via
    the models layer (:func:`devops_bench.models.get_model`); no provider SDK is
    imported directly. The MCP server command is read from ``AGENT_TARGET`` (or
    ``MCP_SERVER_PATH``), and ``bench_use_mcp`` gates whether MCP tools are used.

    Args:
        mcp_server_path: Command launching the MCP server; when ``None`` it is
            resolved from the environment.
        provider: Provider key override; when ``None`` it flows from
            ``AGENT_PROVIDER``.
        model_name: Model override; when ``None`` it flows from ``AGENT_MODEL``.
        bench_use_mcp: Connect to the MCP server and expose its tools; defaults to
            the ``BENCH_USE_MCP`` env flag (``True`` when unset).
    """

    def __init__(
        self,
        mcp_server_path: str | None = None,
        provider: str | None = None,
        model_name: str | None = None,
        bench_use_mcp: bool | None = None,
    ) -> None:
        self.mcp_server_path = (
            mcp_server_path or get_env("AGENT_TARGET") or get_env("MCP_SERVER_PATH")
        )
        self.provider = provider
        self.model_name = model_name
        self.bench_use_mcp = (
            bench_use_mcp if bench_use_mcp is not None else get_bool("BENCH_USE_MCP", True)
        )

    def run(self, prompt: str, context: dict | None = None) -> dict:
        """Run the API agent against ``prompt``.

        Builds the LLM client from the models layer and drives the async MCP
        loop to completion synchronously.

        Args:
            prompt: Task prompt handed to the agent.
            context: Optional context; an ``"system_instruction"`` key is
                forwarded to the loop when present.

        Returns:
            The standardized result dict (``output``, ``latency``, ``tokens``,
            ``tools``, ``trajectory``, ``skills``).
        """
        llm_client = get_model(self.provider, self.model_name)
        system_instruction = (context or {}).get("system_instruction")
        return asyncio.run(
            run_api_agent(
                prompt,
                self.mcp_server_path,
                llm_client,
                bench_use_mcp=self.bench_use_mcp,
                system_instruction=system_instruction,
            )
        )
