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

"""Unit tests for devops_bench.agents.api.loop."""

from __future__ import annotations

import asyncio

import pytest

from devops_bench.agents.api import loop
from devops_bench.agents.base import AGENTS


@pytest.fixture(autouse=True)
def _no_observe(mocker):
    # deepeval's @observe is imported lazily inside the functions; replace it with
    # an identity decorator so no real tracing runs.
    mocker.patch("deepeval.tracing.observe", lambda *a, **k: (lambda fn: fn))


class _Usage:
    prompt_token_count = 3
    candidates_token_count = 5
    total_token_count = 8


class _Response:
    """Raw response stand-in carrying optional function calls and usage."""

    def __init__(self, text="", function_calls=None, usage=None):
        self.text = text
        self.function_calls = function_calls or []
        self.usage_metadata = usage


class _FakeLLMClient:
    """Neutral LLMClient stand-in scripted with a queue of responses."""

    def __init__(self, responses):
        self._responses = list(responses)
        self.generate_calls = 0

    async def generate_content(self, contents, tools, system_instruction):
        self.generate_calls += 1
        return self._responses.pop(0)

    def format_tools(self, mcp_tools):
        return list(mcp_tools)

    def extract_function_calls(self, response):
        return response.function_calls

    def get_text_content(self, response):
        return response.text


class _FakeMCPClient:
    """Minimal MCP client stand-in for tool execution and skill resources."""

    def __init__(self):
        self.skill_resources = {}
        self.calls = []

    async def call_tool(self, name, args):
        self.calls.append((name, args))

        class _Result:
            content = [type("C", (), {"text": f"result-of-{name}"})()]

        return _Result()


def test_registered_under_api():
    assert AGENTS.get("api") is loop.ApiAgent


def test_parse_skill_md_extracts_frontmatter(tmp_path):
    f = tmp_path / "SKILL.md"
    f.write_text('---\nname: "my-skill"\ndescription: does things\n---\nbody text\n')
    name, description, content = loop.parse_skill_md(str(f))
    assert name == "my-skill"
    assert description == "does things"
    assert "body text" in content


def test_parse_skill_md_missing_file_returns_none():
    assert loop.parse_skill_md("/nonexistent/SKILL.md") == (None, None, None)


def test_process_query_no_function_calls_appends_assistant():
    client = _FakeLLMClient([_Response(text="all done")])
    contents = [{"role": "user", "content": "hi"}]

    response, out_contents, duration = asyncio.run(
        loop.process_query(client, contents, [], None, None)
    )
    assert out_contents[-1] == {"role": "assistant", "content": "all done"}
    assert duration >= 0.0


def test_process_query_executes_tool_call():
    fc = [{"name": "do_thing", "args": {"a": 1}, "id": "call-1"}]
    client = _FakeLLMClient([_Response(text="", function_calls=fc)])
    mcp = _FakeMCPClient()
    contents = [{"role": "user", "content": "hi"}]

    asyncio.run(loop.process_query(client, contents, [], None, mcp))

    assert mcp.calls == [("do_thing", {"a": 1})]
    tool_msg = contents[-1]
    assert tool_msg["role"] == "tool"
    assert tool_msg["name"] == "do_thing"
    assert tool_msg["content"] == "result-of-do_thing"


def test_process_query_skill_tool_reads_file(tmp_path):
    skill_file = tmp_path / "SKILL.md"
    skill_file.write_text("skill contents here")

    fc = [{"name": "skill_foo", "args": {}, "id": "call-1"}]
    client = _FakeLLMClient([_Response(text="", function_calls=fc)])
    mcp = _FakeMCPClient()
    mcp.skill_resources = {"skill_foo": str(skill_file)}
    contents = [{"role": "user", "content": "hi"}]

    asyncio.run(loop.process_query(client, contents, [], None, mcp))

    assert mcp.calls == []  # skill tools never hit the MCP server
    assert contents[-1]["content"] == "skill contents here"


def test_process_query_tool_error_is_captured():
    fc = [{"name": "boom", "args": {}, "id": "call-1"}]
    client = _FakeLLMClient([_Response(text="", function_calls=fc)])

    class _ExplodingMCP:
        skill_resources = {}

        async def call_tool(self, name, args):
            raise RuntimeError("kaboom")

    contents = [{"role": "user", "content": "hi"}]
    asyncio.run(loop.process_query(client, contents, [], None, _ExplodingMCP()))

    assert contents[-1]["role"] == "tool"
    assert "Error: kaboom" in contents[-1]["content"]


def test_run_api_agent_no_mcp_loops_to_completion():
    # Turn 1 requests a (no-op) tool-less response immediately to terminate.
    client = _FakeLLMClient([_Response(text="final answer", usage=_Usage())])

    result = asyncio.run(loop.run_api_agent("goal", None, client, bench_use_mcp=False))

    assert result["output"] == "final answer"
    assert result["skills"] == []
    assert result["tools"] == []
    assert result["tokens"]["total_tokens"] == 8
    assert result["trajectory"][0] == {"type": "user_input", "content": "goal"}


def test_run_api_agent_multi_turn_with_tools():
    fc = [{"name": "do_thing", "args": {"a": 1}, "id": "call-1"}]
    responses = [
        _Response(text="", function_calls=fc),  # turn 1: call a tool
        _Response(text="done", usage=_Usage()),  # turn 2: finish
    ]
    client = _FakeLLMClient(responses)

    # Patch MCPClient so no real server is spawned; provide tools via list_tools.
    class _MCPCtx:
        def __init__(self, *a, **k):
            self.skill_resources = {}

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

        async def list_tools(self):
            return type("R", (), {"tools": []})()

        async def call_tool(self, name, args):
            class _Result:
                content = [type("C", (), {"text": "ok"})()]

            return _Result()

    import devops_bench.agents.api.loop as loop_mod

    orig = loop_mod.MCPClient
    loop_mod.MCPClient = _MCPCtx
    try:
        result = asyncio.run(loop.run_api_agent("goal", "server", client, bench_use_mcp=True))
    finally:
        loop_mod.MCPClient = orig

    assert result["output"] == "done"
    assert result["tools"] == ["do_thing"]
    assert client.generate_calls == 2


class _RunawayLLMClient:
    """LLMClient stand-in that never stops requesting tools (to test the cap)."""

    def __init__(self):
        self.generate_calls = 0

    async def generate_content(self, contents, tools, system_instruction):
        self.generate_calls += 1
        return _Response(
            text="still going", function_calls=[{"name": "loop_tool", "args": {}, "id": "x"}]
        )

    def format_tools(self, mcp_tools):
        return list(mcp_tools)

    def extract_function_calls(self, response):
        return response.function_calls

    def get_text_content(self, response):
        return response.text


def test_run_agent_loop_terminates_at_turn_cap():
    client = _RunawayLLMClient()
    mcp = _FakeMCPClient()

    result = asyncio.run(
        loop._run_agent_loop("goal", [], mcp, client, skills=[], max_turns=3)
    )

    assert client.generate_calls == 3  # stopped exactly at the cap, not forever
    assert result["tools"] == ["loop_tool"]
    assert result["output"] == "still going"


def test_run_agent_loop_cap_reads_env(monkeypatch):
    monkeypatch.setenv("AGENT_MAX_TURNS", "2")
    client = _RunawayLLMClient()
    mcp = _FakeMCPClient()

    asyncio.run(loop._run_agent_loop("goal", [], mcp, client, skills=[]))

    assert client.generate_calls == 2


def test_api_agent_run_uses_models_layer(mocker):
    fake_client = _FakeLLMClient([_Response(text="hello", usage=_Usage())])
    get_model = mocker.patch.object(loop, "get_model", return_value=fake_client)

    agent = loop.ApiAgent(mcp_server_path="server", bench_use_mcp=False)
    result = agent.run("do the task", context={"system_instruction": "be brief"})

    assert result["output"] == "hello"
    get_model.assert_called_once_with(agent.provider, agent.model_name)


def test_api_agent_reads_config(monkeypatch):
    monkeypatch.setenv("AGENT_TARGET", "/path/to/mcp")
    monkeypatch.setenv("BENCH_USE_MCP", "false")
    agent = loop.ApiAgent()
    assert agent.mcp_server_path == "/path/to/mcp"
    assert agent.bench_use_mcp is False
