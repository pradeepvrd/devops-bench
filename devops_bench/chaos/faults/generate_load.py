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

"""The ``generate_load`` fault: LLM-driven fortio/kubectl traffic spikes."""

from __future__ import annotations

import json
import os
import shlex
import threading
from typing import Any

from devops_bench.chaos.base import FAULTS, Fault
from devops_bench.core import get_logger
from devops_bench.core.subprocess import run

__all__ = ["GenerateLoadFault", "run_chaos_command"]

_log = get_logger("chaos.generate_load")

# Marker substring that, when present in a command, indicates a load spike is
# active. The harness watches the shared event to coordinate measurements.
_LOAD_MARKER = "fortio load"

# Wall-clock ceiling for a single chaos command, matching legacy behavior.
_COMMAND_TIMEOUT = 40


def run_chaos_command(
    command: str,
    chaos_active_event: threading.Event | None = None,
) -> str:
    """Execute a single chaos command and return its combined output.

    The command is a single, non-piped command string produced by the LLM (e.g.
    a ``fortio load`` invocation). It is tokenized with :func:`shlex.split` and
    run shell-free, so shell features (pipes, redirection, ``$VAR``) are not
    supported; a leading ``~`` in each token is expanded to the user's home.
    When the command is a load spike and an event is supplied, the event is set
    so the harness can observe that load is active before measuring impact.

    Args:
        command: Single command to execute (no shell pipelines or redirection).
        chaos_active_event: Optional event signaled when a load spike starts.

    Returns:
        A string combining stdout and stderr, or an ``Error:`` description if
        the command could not be run.
    """
    if not command.strip():
        return "Error: command string is empty"

    try:
        _log.info("running chaos command: %s", command)

        # The model emits shell strings (e.g. a single fortio invocation); split
        # into argv so execution stays shell-free. shlex.split does not expand
        # ``~``, so expand each token's leading home to keep ``~/go/bin/fortio``
        # style paths resolvable. Shell features (pipes, redirection, $VARS) are
        # not supported by this argv executor.
        argv = [os.path.expanduser(arg) for arg in shlex.split(command)]

        # Signal "load active" only once the command parses cleanly and we are
        # about to execute it, so a parse failure never falsely tells the harness
        # that load is live.
        if chaos_active_event is not None and _LOAD_MARKER in command:
            _log.info("load spike detected; signaling harness via chaos event")
            chaos_active_event.set()

        completed = run(argv, check=False, timeout=_COMMAND_TIMEOUT)
        return f"Stdout:\n{completed.stdout}\nStderr:\n{completed.stderr}"
    except Exception as exc:  # noqa: BLE001 - surface any failure back to the LLM
        return f"Error: {exc}"


@FAULTS.register("generate_load")
class GenerateLoadFault(Fault):
    """A traffic-spike fault driven by an LLM issuing fortio commands.

    The fault exposes a single command-execution capability to the model and
    relies on the agent loop to plan and issue exactly one ``fortio load``
    spike against the port-forwarded target.

    Attributes:
        id: Identifier (``"generate_load"``).
        name: Human-readable name.
        target_subsystem: Targeted subsystem (``"traffic"``).
    """

    id = "generate_load"
    name = "Generate Load"
    target_subsystem = "traffic"

    def __init__(self) -> None:
        self._spec: dict[str, Any] = {}

    def get_agnostic_spec(self) -> dict[str, Any]:
        """Return the platform-agnostic spec last injected.

        Returns:
            The most recent spec dict, or an empty dict before injection.
        """
        return dict(self._spec)

    def goal(self, spec: dict[str, Any]) -> str:
        """Build the planned-mode goal prompt for the LLM.

        The fortio target URL is read from the spec (``target.service_url``,
        rewritten by the harness to the local port-forward) so the spec field
        drives the prompt rather than a hardcoded constant.

        Args:
            spec: The chaos task spec describing the load to generate.

        Returns:
            The goal prompt instructing the model to issue one fortio spike.
        """
        # Imported here (not at module top) to keep the fault module free of the
        # agent + models layer until injection actually runs.
        from devops_bench.chaos.agent import target_url_from_spec

        target_url = target_url_from_spec(spec)
        return (
            "Your goal is to execute the following GKE planned chaos engineering "
            "disruption action:\n"
            f"```json\n{json.dumps(spec, indent=2)}\n```\n\n"
            "Guidelines for execution:\n"
            "1. Use the 'fortio' tool to inject traffic into GKE.\n"
            "2. Note: GKE service target URLs (like *.svc.cluster.local) are "
            f"port-forwarded to '{target_url}' on the host, so run fortio "
            f"against {target_url} instead.\n"
            "Use your run_command tool to execute this disruption safely and effectively."
        )

    def inject(
        self, spec: dict[str, Any], context: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        """Inject the load fault by running a single LLM-planned chaos loop.

        Args:
            spec: The chaos task spec; its ``type`` must be ``"generate_load"``.
            context: Optional context; ``chaos_active_event`` (a
                :class:`threading.Event`) is signaled when load starts.

        Returns:
            A report dict with ``status`` and the model's final ``output``.

        Raises:
            ValueError: If ``spec['type']`` is not ``"generate_load"``.
        """
        action_type = spec.get("type")
        if action_type != self.id:
            raise ValueError(f"unsupported chaos action type {action_type!r} for {self.id!r}")

        self._spec = dict(spec)
        # Deferred import keeps base/fault imports free of the agent + models layer.
        from devops_bench.chaos.agent import (
            ChaosAgent,
            build_system_instruction,
            target_url_from_spec,
        )

        event = (context or {}).get("chaos_active_event")
        # Inject the spec's target URL into both the goal and the system prompt.
        system_instruction = build_system_instruction(target_url_from_spec(spec))
        agent = ChaosAgent(chaos_active_event=event, system_instruction=system_instruction)
        output = agent.run(self.goal(spec))
        return {"status": "completed", "output": output}
