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

"""MCP capability: binding data + agent-side Protocol/mixin.

The :class:`McpBinding` is **data supplied by the orchestrator** describing one
MCP server an agent may use (its launch command and the list of tools to
expose / pre-approve). The :class:`SupportsMcp` Protocol marks an agent that
*can* drive MCP at all; :class:`McpMixin` is the trivial implementation an
agent inherits to declare the capability.

Per the handoff (§5), "GKE" is never a type and never a string literal inside
agent code — it is a *value* the orchestrator puts in a binding. This module
carries no provider/cluster-specific strings.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol, runtime_checkable

__all__ = ["McpBinding", "SupportsMcp", "McpMixin"]


@dataclass(frozen=True)
class McpBinding:
    """One MCP server an agent may drive during a run.

    Bindings are **plain data**, constructed by the orchestrator from a
    benchmark catalog and threaded through :class:`~devops_bench.agents.config.AgentConfig`.
    A binding with an empty ``command`` is valid for CLI agents whose binary
    launches its own MCP infrastructure (e.g. Gemini's built-in MCP host); the
    binding still carries the ``tools`` list so the agent knows what to
    advertise / pre-approve.

    Attributes:
        name: Human-readable label for the server (e.g. ``"gke"``). Metadata
            only — never inspected to gate behavior; that would re-introduce the
            "string-typed capability" anti-pattern PR3 removes.
        command: argv-style command launching the MCP server, or ``()`` when
            the agent runs MCP in-process. The API agent feeds this to
            :class:`~devops_bench.agents.api.mcp.MCPClient`.
        tools: Tool names this server exposes to the agent. The Gemini CLI
            passes these via ``--allowed-tools``; the API agent advertises
            whatever the live MCP server lists (this field acts as
            documentation / pre-approval there).
    """

    name: str = ""
    command: tuple[str, ...] = ()
    tools: tuple[str, ...] = ()


@runtime_checkable
class SupportsMcp(Protocol):
    """Structural marker for an agent that can drive MCP servers.

    The orchestrator runs ``isinstance(agent, SupportsMcp)`` before granting
    an MCP binding so a task requiring MCP never silently runs against an
    agent that ignores it. Protocol membership is granted by the trivial
    :class:`McpMixin` (or any class with a ``mcp_servers`` attribute typed as
    ``tuple[McpBinding, ...]``).
    """

    mcp_servers: tuple[McpBinding, ...]


@dataclass
class McpMixin:
    """Default-implementation mixin granting :class:`SupportsMcp`.

    Concrete agents inherit this mixin to declare they accept MCP bindings;
    they read ``self.mcp_servers`` (typically populated from
    ``config.capabilities.mcp_servers``) to wire the actual sessions. The
    mixin holds no behavior — capability negotiation is purely structural.

    Attributes:
        mcp_servers: The bindings granted to this agent for the current run.
            Default ``()`` keeps a freshly constructed agent disabled.
    """

    mcp_servers: tuple[McpBinding, ...] = field(default_factory=tuple)
