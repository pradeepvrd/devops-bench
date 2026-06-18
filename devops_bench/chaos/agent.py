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

"""LLM-driven orchestration loop for injecting chaos faults."""

from __future__ import annotations

import asyncio
import threading
from collections.abc import Callable
from types import SimpleNamespace
from typing import Any

from devops_bench.core import first_env, get_logger
from devops_bench.models import LLMClient, get_model

__all__ = [
    "ChaosAgent",
    "SYSTEM_INSTRUCTION",
    "RUN_COMMAND_TOOL",
    "build_system_instruction",
    "target_url_from_spec",
]

_log = get_logger("chaos.agent")

# Single source of truth for the load target when a spec omits one. The local
# port-forward URL the cluster workload is exposed on by the harness.
_DEFAULT_TARGET_URL = "http://localhost:8080"


def build_system_instruction(target_url: str = _DEFAULT_TARGET_URL) -> str:
    """Build the SRE system instruction, targeting ``target_url`` for load.

    Args:
        target_url: URL fortio load should be directed at. Flows from the chaos
            spec's ``target.service_url`` (rewritten by the harness to the local
            port-forward), defaulting to :data:`_DEFAULT_TARGET_URL`.

    Returns:
        The system instruction string with the target URL injected.
    """
    return (
        "You are a professional Site Reliability Engineer (SRE) and Chaos Engineering Expert.\n"
        "Your role is to disrupt GKE workloads to test system resilience, which can happen in "
        "two modes:\n"
        "1. Planned Mode: Execute a specific GKE chaos disruption according to a provided JSON "
        "spec.\n"
        "2. Autonomous Mode: Autonomously explore the GKE cluster state, identify critical "
        "targets (pods, nodes, services), and inject transient faults to test recovery.\n\n"
        "You are equipped with the `run_command` tool, which runs a single command locally on "
        "the GKE host control machine (which is fully authenticated and has GKE admin kubectl "
        "privileges). Each call must be ONE non-piped command: shell pipelines, redirection, "
        "command chaining (``|``, ``>``, ``&&``, ``;``) and environment-variable interpolation "
        "(``$VAR``) are NOT supported.\n\n"
        "Strict Guidelines for Execution:\n"
        "- Single Execution Policy: You MUST execute exactly one tool call to run the planned "
        "'fortio' load generation spike. Do NOT attempt to rerun, adjust, or tune the load "
        "generation if the target service saturates or returns timeouts. Once the single load "
        "command is executed, analyze the output, write your final performance summary, and exit "
        "immediately.\n"
        "- Safety First: Only inject transient, safe, and recoverable faults (e.g. killing pods, "
        "scaling deployments, generating traffic spikes). Do NOT permanently destroy GKE "
        "clusters, namespaces, or nodes.\n"
        "- Traffic Generation: For load spikes, use the 'fortio' binary. Since GKE internal "
        "service URLs (*.svc.cluster.local) are port-forwarded to the host, you MUST target "
        f"'{target_url}' instead.\n"
        "- Analysis & Clarity: Analyze command outputs carefully, report stdout/stderr "
        "accurately, and confirm in your final response when the disruption has been "
        "successfully completed."
    )


def target_url_from_spec(spec: dict[str, Any] | None) -> str:
    """Extract the load target URL from a chaos spec/action.

    Reads ``spec['target']['service_url']`` (the action shape the harness hands
    in after rewriting it to the local port-forward), falling back to
    :data:`_DEFAULT_TARGET_URL` when absent or malformed.

    Args:
        spec: A chaos spec or action dict, or None.

    Returns:
        The target URL, or the module default when none is present.
    """
    if not isinstance(spec, dict):
        return _DEFAULT_TARGET_URL
    target = spec.get("target")
    if isinstance(target, dict):
        url = target.get("service_url")
        if isinstance(url, str) and url.strip():
            return url
    return _DEFAULT_TARGET_URL


# Default system instruction using the fallback target URL. Callers that know
# the spec's target should build a tailored one via build_system_instruction.
SYSTEM_INSTRUCTION = build_system_instruction()

# Neutral, duck-typed tool descriptor consumed by ``LLMClient.format_tools``
# (mirrors the MCP tool shape: name/description/inputSchema).
RUN_COMMAND_TOOL = SimpleNamespace(
    name="run_command",
    description=(
        "Run a shell command on the GKE host control machine (authenticated kubectl + fortio). "
        "Returns combined stdout and stderr."
    ),
    inputSchema={
        "type": "object",
        "properties": {
            "command": {
                "type": "string",
                "description": "The shell command to execute, e.g. a fortio load invocation.",
            }
        },
        "required": ["command"],
    },
)

# Safety bound on the agent loop so a misbehaving model cannot spin forever.
_MAX_TURNS = 8


class ChaosAgent:
    """Drives an LLM through a tool-calling loop to inject chaos faults.

    The agent is provider-agnostic: it obtains an :class:`LLMClient` from the
    models layer and never imports a provider SDK. The model is given a single
    ``run_command`` tool and loops until it stops requesting tool calls.

    Args:
        chaos_active_event: Optional event signaled when a load spike starts,
            so the harness can coordinate measurements.
        client: Optional pre-built LLM client; when omitted one is selected
            from configuration via :func:`get_model`.
        system_instruction: System prompt for the loop; defaults to
            :data:`SYSTEM_INSTRUCTION`.
        tools: Tool descriptors offered to the model; defaults to
            ``[RUN_COMMAND_TOOL]``.
        tool_handler: Callable invoked for a ``run_command`` tool call as
            ``tool_handler(command, chaos_active_event) -> str``. Defaults to
            :func:`devops_bench.chaos.faults.generate_load.run_chaos_command`,
            imported lazily so the orchestrator does not couple to the concrete
            fault at module load.
    """

    def __init__(
        self,
        chaos_active_event: threading.Event | None = None,
        client: LLMClient | None = None,
        system_instruction: str | None = None,
        tools: list[Any] | None = None,
        tool_handler: Callable[[str, threading.Event | None], str] | None = None,
    ) -> None:
        self._chaos_active_event = chaos_active_event
        if client is None:
            provider = first_env("CHAOS_PROVIDER", "AGENT_PROVIDER")
            model_name = first_env("CHAOS_MODEL", "AGENT_MODEL")
            client = get_model(provider=provider, model_name=model_name)
        self._client = client
        self._system_instruction = (
            system_instruction if system_instruction is not None else SYSTEM_INSTRUCTION
        )
        self._tools = tools if tools is not None else [RUN_COMMAND_TOOL]
        if tool_handler is None:
            # Lazy import avoids a top-level agent -> concrete-fault dependency.
            from devops_bench.chaos.faults.generate_load import run_chaos_command

            tool_handler = run_chaos_command
        self._tool_handler = tool_handler

    def run(self, goal: str) -> str:
        """Run the chaos loop synchronously and return the model's final text.

        Args:
            goal: The planned-mode goal prompt for the model.

        Returns:
            The model's final text response once it stops calling tools.
        """
        return asyncio.run(self._run_async(goal))

    async def _run_async(self, goal: str) -> str:
        client = self._client
        tools = client.format_tools(self._tools)
        contents: list[dict[str, Any]] = [{"role": "user", "content": goal}]

        final_text = ""
        for turn in range(_MAX_TURNS):
            _log.info("chaos agent turn %d", turn + 1)
            response = await client.generate_content(
                contents, tools, self._system_instruction
            )
            text = client.get_text_content(response)
            function_calls = client.extract_function_calls(response)

            assistant_message: dict[str, Any] = {"role": "assistant", "content": text}
            if function_calls:
                assistant_message["tool_calls"] = function_calls
            contents.append(assistant_message)

            # Retain the latest text on every turn so a tool call on the final
            # turn (or the turn cap) does not discard the model's accompanying
            # summary.
            final_text = text

            if not function_calls:
                _log.info("chaos agent finished: no further tool calls")
                break

            for call in function_calls:
                result = self._execute_tool(call.get("name"), call.get("args"))
                contents.append(
                    {
                        "role": "tool",
                        "tool_call_id": call.get("id"),
                        "name": call.get("name"),
                        "content": result,
                    }
                )
        else:
            _log.warning("chaos agent stopped after reaching the turn limit (%d)", _MAX_TURNS)

        return final_text

    def _execute_tool(self, name: str | None, args: Any) -> str:
        """Dispatch a model tool call to its implementation.

        Args:
            name: Requested tool name.
            args: Tool arguments from the model; expected to be an object (dict).

        Returns:
            The tool's textual result, or an error description.
        """
        if not isinstance(args, dict):
            return "Error: tool args must be an object"
        if name == RUN_COMMAND_TOOL.name:
            command = args.get("command", "")
            return self._tool_handler(command, self._chaos_active_event)
        return f"Error: unknown tool {name!r}"
