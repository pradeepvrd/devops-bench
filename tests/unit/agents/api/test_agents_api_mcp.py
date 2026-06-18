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

"""Unit tests for devops_bench.agents.api.mcp."""

from __future__ import annotations

import asyncio
import sys
import types

import pytest

from devops_bench.agents.api import mcp as mcp_mod
from devops_bench.core import MissingDependencyError


def test_init_defaults():
    client = mcp_mod.MCPClient("some-server")
    assert client.server_path == "some-server"
    assert client.session is None
    assert client.skill_resources == {}


def test_enter_without_mcp_sdk_raises(mocker):
    # Force the lazy `import mcp.client...` inside __aenter__ to fail.
    real_import = __import__

    def _fake_import(name, *args, **kwargs):
        if name.startswith("mcp.client"):
            raise ImportError("no mcp")
        return real_import(name, *args, **kwargs)

    mocker.patch("builtins.__import__", side_effect=_fake_import)

    client = mcp_mod.MCPClient("server")
    with pytest.raises(MissingDependencyError):
        asyncio.run(client.__aenter__())


def _install_fake_mcp_sdk(mocker):
    """Inject fake ``mcp.client.session``/``mcp.client.stdio`` modules.

    Returns a ``state`` dict that records lifecycle events: ``captured`` (the
    ``StdioServerParameters`` kwargs), ``initialized``/``transport_closed``/
    ``session_closed`` flags, and ``session`` (the fake session, which serves
    canned ``list_tools``/``call_tool`` results). Nothing spawns a real process.
    """
    state: dict = {
        "captured": {},
        "initialized": False,
        "transport_closed": False,
        "session_closed": False,
        "session": None,
    }

    class _StdioServerParameters:
        def __init__(self, **kwargs):
            state["captured"].update(kwargs)

    class _Transport:
        async def __aenter__(self):
            return ("read", "write")

        async def __aexit__(self, *a):
            state["transport_closed"] = True
            return False

    def _stdio_client(_params):
        return _Transport()

    class _ClientSession:
        def __init__(self, read, write):
            self.read = read
            self.write = write
            state["session"] = self

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            state["session_closed"] = True
            return False

        async def initialize(self):
            state["initialized"] = True

        async def list_tools(self):
            return "tools-result"

        async def call_tool(self, name, arguments):
            return f"called {name} with {arguments}"

    session_mod = types.ModuleType("mcp.client.session")
    session_mod.ClientSession = _ClientSession
    stdio_mod = types.ModuleType("mcp.client.stdio")
    stdio_mod.StdioServerParameters = _StdioServerParameters
    stdio_mod.stdio_client = _stdio_client

    mocker.patch.dict(
        sys.modules,
        {"mcp.client.session": session_mod, "mcp.client.stdio": stdio_mod},
    )
    return state


def test_enter_splits_multiword_server_path(mocker):
    state = _install_fake_mcp_sdk(mocker)
    client = mcp_mod.MCPClient("uv run mcp-server")

    asyncio.run(client.__aenter__())

    # The command word is the executable; the rest become args.
    assert state["captured"] == {"command": "uv", "args": ["run", "mcp-server"]}


def test_enter_empty_server_path_raises(mocker):
    _install_fake_mcp_sdk(mocker)
    client = mcp_mod.MCPClient("   ")

    with pytest.raises(ValueError, match="empty"):
        asyncio.run(client.__aenter__())


def test_list_tools_delegates_to_session():
    client = mcp_mod.MCPClient("server")

    class _Session:
        async def list_tools(self):
            return "tools-result"

    client.session = _Session()
    assert asyncio.run(client.list_tools()) == "tools-result"


def test_call_tool_delegates_and_observes(mocker):
    # @observe is imported lazily inside call_tool; make it an identity decorator.
    mocker.patch("deepeval.tracing.observe", lambda *a, **k: (lambda fn: fn))

    captured = {}

    class _Session:
        async def call_tool(self, name, arguments):
            captured["name"] = name
            captured["arguments"] = arguments
            return "tool-output"

    client = mcp_mod.MCPClient("server")
    client.session = _Session()

    result = asyncio.run(client.call_tool("do_thing", {"x": 1}))
    assert result == "tool-output"
    assert captured == {"name": "do_thing", "arguments": {"x": 1}}
