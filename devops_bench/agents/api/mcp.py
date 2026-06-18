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

"""Async MCP client wrapping the ``mcp`` SDK over a stdio server transport."""

from __future__ import annotations

from contextlib import AsyncExitStack
from typing import Any

from devops_bench.core import MissingDependencyError, get_logger

__all__ = ["MCPClient"]

_log = get_logger("agents.api.mcp")


class MCPClient:
    """Async context manager over an MCP stdio server.

    Spawns the MCP server given by ``server_path``, initializes a session, and
    exposes tool discovery and invocation. The ``mcp`` SDK is imported lazily on
    ``__aenter__`` so merely importing this module never requires the SDK.

    Attributes:
        server_path: Command used to launch the MCP server over stdio.
        session: The active ``ClientSession`` once entered, else ``None``.
        skill_resources: Map of synthetic skill-tool name to local file path,
            populated by callers that expose local skills as pseudo-tools.

    Raises:
        MissingDependencyError: If the ``mcp`` SDK is not installed (on enter).
    """

    def __init__(self, server_path: str) -> None:
        self.server_path = server_path
        self.exit_stack = AsyncExitStack()
        self.session: Any = None
        self.skill_resources: dict[str, str] = {}

    async def __aenter__(self) -> MCPClient:
        try:
            from mcp.client.session import ClientSession
            from mcp.client.stdio import StdioServerParameters, stdio_client
        except ImportError as exc:  # pragma: no cover - exercised via MissingDependencyError
            raise MissingDependencyError("the API agent's MCP client", "mcp") from exc

        server_params = StdioServerParameters(command=self.server_path)
        stdio_transport = await self.exit_stack.enter_async_context(
            stdio_client(server_params)
        )
        self.read_stream, self.write_stream = stdio_transport
        self.session = await self.exit_stack.enter_async_context(
            ClientSession(self.read_stream, self.write_stream)
        )
        await self.session.initialize()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        await self.exit_stack.aclose()

    async def list_tools(self) -> Any:
        """List the tools advertised by the connected MCP server.

        Returns:
            The raw ``list_tools`` result whose ``.tools`` is the tool list.
        """
        return await self.session.list_tools()

    async def call_tool(self, name: str, arguments: dict) -> Any:
        """Invoke an MCP tool by name.

        Args:
            name: Tool name as advertised by the server.
            arguments: Keyword arguments for the tool.

        Returns:
            The raw tool-call result from the MCP session.
        """
        from deepeval.tracing import observe

        @observe(span_type="TOOL")
        async def _call() -> Any:
            return await self.session.call_tool(name, arguments=arguments)

        return await _call()
