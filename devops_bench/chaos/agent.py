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
from types import SimpleNamespace
from typing import Any

from devops_bench.chaos.faults.generate_load import run_chaos_command
from devops_bench.core import first_env, get_logger
from devops_bench.models import LLMClient, get_model

__all__ = ["ChaosAgent", "SYSTEM_INSTRUCTION", "RUN_COMMAND_TOOL"]

_log = get_logger("chaos.agent")

SYSTEM_INSTRUCTION = (
    "You are a professional Site Reliability Engineer (SRE) and Chaos Engineering Expert.\n"
    "Your role is to disrupt GKE workloads to test system resilience, which can happen in "
    "two modes:\n"
    "1. Planned Mode: Execute a specific GKE chaos disruption according to a provided JSON spec.\n"
    "2. Autonomous Mode: Autonomously explore the GKE cluster state, identify critical targets "
    "(pods, nodes, services), and inject transient faults to test recovery.\n\n"
    "You are equipped with the `run_command` tool, which runs shell commands locally on the GKE "
    "host control machine (which is fully authenticated and has GKE admin kubectl privileges).\n\n"
    "Strict Guidelines for Execution:\n"
    "- Single Execution Policy: You MUST execute exactly one tool call to run the planned "
    "'fortio' load generation spike. Do NOT attempt to rerun, adjust, or tune the load "
    "generation if the target service saturates or returns timeouts. Once the single load "
    "command is executed, analyze the output, write your final performance summary, and exit "
    "immediately.\n"
    "- Safety First: Only inject transient, safe, and recoverable faults (e.g. killing pods, "
    "scaling deployments, generating traffic spikes). Do NOT permanently destroy GKE clusters, "
    "namespaces, or nodes.\n"
    "- Traffic Generation: For load spikes, use the 'fortio' binary. Since GKE internal service "
    "URLs (*.svc.cluster.local) are port-forwarded to the host, you MUST target "
    "'http://localhost:8080' instead.\n"
    "- Analysis & Clarity: Analyze command outputs carefully, report stdout/stderr accurately, "
    "and confirm in your final response when the disruption has been successfully completed."
)

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
    """

    def __init__(
        self,
        chaos_active_event: threading.Event | None = None,
        client: LLMClient | None = None,
    ) -> None:
        self._chaos_active_event = chaos_active_event
        if client is None:
            provider = first_env("CHAOS_PROVIDER", "AGENT_PROVIDER")
            model_name = first_env("CHAOS_MODEL", "AGENT_MODEL")
            client = get_model(provider=provider, model_name=model_name)
        self._client = client

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
        tools = client.format_tools([RUN_COMMAND_TOOL])
        contents: list[dict[str, Any]] = [{"role": "user", "content": goal}]

        final_text = ""
        for turn in range(_MAX_TURNS):
            _log.info("chaos agent turn %d", turn + 1)
            response = await client.generate_content(contents, tools, SYSTEM_INSTRUCTION)
            text = client.get_text_content(response)
            function_calls = client.extract_function_calls(response)

            assistant_message: dict[str, Any] = {"role": "assistant", "content": text}
            if function_calls:
                assistant_message["tool_calls"] = function_calls
            contents.append(assistant_message)

            if not function_calls:
                final_text = text
                _log.info("chaos agent finished: no further tool calls")
                break

            for call in function_calls:
                result = self._execute_tool(call.get("name"), call.get("args") or {})
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

    def _execute_tool(self, name: str | None, args: dict[str, Any]) -> str:
        """Dispatch a model tool call to its implementation.

        Args:
            name: Requested tool name.
            args: Tool arguments from the model.

        Returns:
            The tool's textual result, or an error description.
        """
        if name == RUN_COMMAND_TOOL.name:
            command = args.get("command", "")
            return run_chaos_command(command, self._chaos_active_event)
        return f"Error: unknown tool {name!r}"
