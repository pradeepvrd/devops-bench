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

"""The ``generate_load`` fault: LLM-driven fortio traffic spikes.

This module owns every fortio-specific concern: the load-target schema, the
SRE system prompt, the single ``run_command`` tool descriptor, the shell-free
argv executor, and the typed :class:`GenerateLoadFault` node. The chaos agent
itself is fortio-agnostic and pulls these in at injection time.
"""

from __future__ import annotations

import json
import os
import shlex
import threading
import time
from types import SimpleNamespace
from typing import Any, Literal

from pydantic import BaseModel, Field

from devops_bench.chaos.agent import ChaosAgent
from devops_bench.chaos.base import FAULTS, ChaosResult, Fault
from devops_bench.core import get_logger
from devops_bench.core.context import RunContext
from devops_bench.core.subprocess import run

__all__ = [
    "GenerateLoadFault",
    "LoadTarget",
    "RUN_COMMAND_TOOL",
    "build_system_instruction",
    "run_chaos_command",
]

_log = get_logger("chaos.generate_load")

# Marker substring that, when present in a command, indicates a load spike is
# active. The harness watches the shared event to coordinate measurements.
_LOAD_MARKER = "fortio load"

# Wall-clock ceiling for a single chaos command, matching legacy behavior.
_COMMAND_TIMEOUT = 40

# Single source of truth for the load target when a spec omits one. The local
# port-forward URL the cluster workload is exposed on by the harness.
_DEFAULT_TARGET_URL = "http://localhost:8080"


def build_system_instruction(target_url: str = _DEFAULT_TARGET_URL) -> str:
    """Build the SRE system instruction, targeting ``target_url`` for load.

    Args:
        target_url: URL fortio load should be directed at. Flows from the
            fault's ``target.service_url`` (rewritten by the harness to the
            local port-forward), defaulting to :data:`_DEFAULT_TARGET_URL`.

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


def run_chaos_command(
    command: str,
    chaos_active_event: threading.Event | None = None,
) -> str:
    """Execute a single chaos command and return its combined output.

    The command is a single, non-piped string produced by the LLM (typically a
    ``fortio load`` invocation). It is tokenized with :func:`shlex.split` and
    run shell-free, so shell features (pipes, redirection, ``$VAR``) are not
    supported; a leading ``~`` in each token is expanded to the user's home.
    When the command is a load spike and an event is supplied, the event is
    set so the harness can observe that load is active before measuring impact.

    Args:
        command: Single command to execute (no shell pipelines or redirection).
        chaos_active_event: Optional event signaled when a load spike starts.

    Returns:
        A string combining stdout and stderr, or an ``"Error: ..."`` string if
        the command could not be parsed or run.
    """
    if not command.strip():
        return "Error: command string is empty"

    try:
        _log.info("running chaos command: %s", command)

        # The model emits shell strings (e.g. a single fortio invocation); split
        # into argv so execution stays shell-free. shlex.split does not expand
        # ``~``, so expand each token's leading home to keep ``~/go/bin/fortio``
        # style paths resolvable.
        argv = [os.path.expanduser(arg) for arg in shlex.split(command)]

        # Signal "load active" only once the command parses cleanly and we are
        # about to execute it, so a parse failure never falsely tells the
        # harness that load is live.
        if chaos_active_event is not None and _LOAD_MARKER in command:
            _log.info("load spike detected; signaling harness via chaos event")
            chaos_active_event.set()

        completed = run(argv, check=False, timeout=_COMMAND_TIMEOUT)
        return f"Stdout:\n{completed.stdout}\nStderr:\n{completed.stderr}"
    except Exception as exc:  # noqa: BLE001 - surface any failure back to the LLM
        return f"Error: {exc}"


class LoadTarget(BaseModel):
    """Target for a generated load spike.

    Attributes:
        service_url: HTTP URL the load should be directed at. The harness
            rewrites in-cluster ``*.svc.cluster.local`` URLs to the local
            port-forward before injection.
        qps: Target queries per second; the LLM passes this to fortio.
        duration: Optional fortio duration string (e.g. ``"30s"``). When
            omitted, the model picks one consistent with the goal.
        concurrency: Optional fortio ``-c`` concurrency override.
    """

    service_url: str
    qps: int = Field(default=100, ge=1)
    duration: str | None = None
    concurrency: int | None = Field(default=None, ge=1)


@FAULTS.register("generate_load")
class GenerateLoadFault(Fault):
    """A traffic-spike fault driven by an LLM issuing fortio commands.

    The fault exposes a single command-execution capability to the model and
    relies on the agent loop to plan and issue exactly one ``fortio load``
    spike against the port-forwarded target.

    Attributes:
        type: Discriminator literal, always ``"generate_load"``.
        target: Typed load-target description (URL, qps, optional duration /
            concurrency).
    """

    type: Literal["generate_load"] = "generate_load"
    target: LoadTarget

    def goal(self) -> str:
        """Build the planned-mode goal prompt for the LLM.

        The target URL is read from :attr:`target` (rewritten by the harness to
        the local port-forward) so the model's prompt always agrees with the
        rewritten action.

        Returns:
            The goal prompt instructing the model to issue one fortio spike.
        """
        spec_dump: dict[str, Any] = self.model_dump(exclude_none=True)
        target_url = self.target.service_url
        return (
            "Your goal is to execute the following GKE planned chaos engineering "
            "disruption action:\n"
            f"```json\n{json.dumps(spec_dump, indent=2)}\n```\n\n"
            "Guidelines for execution:\n"
            "1. Use the 'fortio' tool to inject traffic into GKE.\n"
            "2. Note: GKE service target URLs (like *.svc.cluster.local) are "
            f"port-forwarded to '{target_url}' on the host, so run fortio "
            f"against {target_url} instead.\n"
            "Use your run_command tool to execute this disruption safely and effectively."
        )

    def inject(
        self,
        ctx: RunContext,
        chaos_active_event: threading.Event | None = None,
    ) -> ChaosResult:
        """Run the LLM-planned chaos loop and return its typed outcome.

        Args:
            ctx: Run context (unused for this fault today; carried for
                interface symmetry and future cluster-aware faults).
            chaos_active_event: Optional event the executor signals when a
                load spike starts, so the harness can synchronize measurements.

        Returns:
            A :class:`ChaosResult` whose ``success`` is True on a clean loop
            completion. Exceptions raised by the agent are converted to
            ``success=False`` with the failure surfaced in ``error``.
        """
        del ctx  # unused today; faults targeting cluster state will consume it.
        start = time.monotonic()
        system_instruction = build_system_instruction(self.target.service_url)
        agent = ChaosAgent(
            system_instruction=system_instruction,
            tool=RUN_COMMAND_TOOL,
            tool_handler=run_chaos_command,
            chaos_active_event=chaos_active_event,
        )
        try:
            output = agent.run(self.goal())
        except Exception as exc:  # noqa: BLE001 - one fault must never abort the run
            elapsed = time.monotonic() - start
            _log.exception("generate_load fault crashed")
            return ChaosResult(
                success=False,
                injected_fault=self.type,
                output="",
                elapsed_time=elapsed,
                error=f"{type(exc).__name__}: {exc}",
            )
        elapsed = time.monotonic() - start
        return ChaosResult(
            success=True,
            injected_fault=self.type,
            output=output,
            elapsed_time=elapsed,
        )
