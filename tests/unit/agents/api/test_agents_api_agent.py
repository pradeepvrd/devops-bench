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

"""Unit tests for :mod:`devops_bench.agents.api.agent`."""

from __future__ import annotations

from dataclasses import dataclass, field
from types import SimpleNamespace
from typing import Any

import pytest

from devops_bench.agents import AGENTS, AgentConfig
from devops_bench.agents.api import agent as agent_mod
from devops_bench.agents.api.agent import (
    ApiAgent,
    extract_tokens,
    fold_trajectory,
)
from devops_bench.models.base import LLMClient

# ---------------------------------------------------------------------------
# Test doubles
# ---------------------------------------------------------------------------


@dataclass
class _Turn:
    """One scripted response in :class:`_FakeLLMClient`.

    Attributes:
        text: ``get_text_content`` payload for this turn.
        calls: Function calls returned by ``extract_function_calls`` (each in
            the neutral ``{"name", "args", "id"}`` shape).
        usage: Optional duck-typed usage object surfaced on the raw response.
    """

    text: str
    calls: list[dict] = field(default_factory=list)
    usage: Any = None


class _FakeLLMClient(LLMClient):
    """Scripted :class:`LLMClient` that returns ``_Turn`` objects in order.

    Records every ``generate_content`` invocation and tracks whether
    ``format_tools`` was called so the agent's caller-formats-tools contract is
    asserted.
    """

    def __init__(self, turns: list[_Turn]) -> None:
        self._turns = list(turns)
        self.calls: list[dict] = []
        self.format_tools_calls: list[Any] = []

    async def generate_content(
        self,
        contents: list[dict[str, Any]],
        tools: Any,
        system_instruction: str | None,
    ) -> Any:
        if not self._turns:
            raise AssertionError("FakeLLMClient ran out of scripted turns")
        turn = self._turns.pop(0)
        self.calls.append(
            {
                "contents": [dict(msg) for msg in contents],
                "tools": tools,
                "system_instruction": system_instruction,
            }
        )
        response = SimpleNamespace(text=turn.text, calls=turn.calls)
        if turn.usage is not None:
            response.usage_metadata = turn.usage
        return response

    def format_tools(self, mcp_tools: Any) -> Any:
        # Snapshot so tests can assert the agent does pre-format tools before
        # calling the loop.
        self.format_tools_calls.append(list(mcp_tools))
        return ("formatted", tuple(getattr(t, "name", "") for t in mcp_tools))

    def extract_function_calls(self, response: Any) -> list[dict]:
        return list(response.calls)

    def get_text_content(self, response: Any) -> str:
        return response.text


class _FakeMCPClient:
    """Stand-in for :class:`MCPClient` exposing only what the agent uses.

    Records every call so tests assert dispatch hit MCP (or skipped it).
    """

    def __init__(self, tools: list[Any] | None = None) -> None:
        self._tools = list(tools or [])
        self.calls: list[tuple[str, dict]] = []
        self.entered = False
        self.exited = False

    async def __aenter__(self) -> _FakeMCPClient:
        self.entered = True
        return self

    async def __aexit__(self, *_a: Any) -> None:
        self.exited = True

    async def list_tools(self) -> Any:
        return SimpleNamespace(tools=self._tools)

    async def call_tool(self, name: str, arguments: dict) -> Any:
        self.calls.append((name, arguments))
        block = SimpleNamespace(text=f"mcp-result-of-{name}")
        return SimpleNamespace(content=[block])


# ---------------------------------------------------------------------------
# Registration & registry wiring
# ---------------------------------------------------------------------------


def test_api_agent_registered_under_canonical_key():
    assert AGENTS.get("api") is ApiAgent


# ---------------------------------------------------------------------------
# fold_trajectory
# ---------------------------------------------------------------------------


def test_fold_trajectory_pairs_assistant_calls_with_tool_results():
    contents = [
        {"role": "user", "content": "g"},
        {
            "role": "assistant",
            "content": "thinking",
            "tool_calls": [
                {"name": "alpha", "args": {"a": 1}, "id": "1"},
                {"name": "beta", "args": {"b": 2}, "id": "2"},
            ],
        },
        {"role": "tool", "tool_call_id": "1", "name": "alpha", "content": "A-result"},
        {"role": "tool", "tool_call_id": "2", "name": "beta", "content": "B-result"},
        {"role": "assistant", "content": "all done"},
    ]
    assert fold_trajectory(contents) == [
        {"name": "alpha", "args": {"a": 1}, "result": "A-result", "status": "completed"},
        {"name": "beta", "args": {"b": 2}, "result": "B-result", "status": "completed"},
    ]


def test_fold_trajectory_marks_dispatcher_errors_as_error_status():
    # The dispatcher returns ``"Error: ..."`` for a failed tool call (matching
    # the agent's _build_dispatch contract) — folding must surface that as the
    # ``"error"`` status so metrics see the failure mode, not a clean call.
    contents = [
        {"role": "user", "content": "g"},
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [{"name": "boom", "args": {}, "id": "x"}],
        },
        {"role": "tool", "tool_call_id": "x", "name": "boom", "content": "Error: kaboom"},
        {"role": "assistant", "content": "abort"},
    ]
    folded = fold_trajectory(contents)
    assert folded == [
        {"name": "boom", "args": {}, "result": "Error: kaboom", "status": "error"},
    ]


def test_fold_trajectory_leaves_unmatched_call_as_called_status():
    # If a result never lands (e.g. dispatch raised before appending), the call
    # entry survives with ``status="called"`` and ``result=None`` rather than
    # being silently dropped.
    contents = [
        {"role": "user", "content": "g"},
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [{"name": "lost", "args": {}, "id": "9"}],
        },
    ]
    assert fold_trajectory(contents) == [
        {"name": "lost", "args": {}, "result": None, "status": "called"},
    ]


def test_fold_trajectory_skips_text_only_turns():
    contents = [
        {"role": "user", "content": "hi"},
        {"role": "assistant", "content": "hello"},
        {"role": "assistant", "content": "bye"},
    ]
    assert fold_trajectory(contents) == []


def test_fold_trajectory_handles_none_args_and_none_call_id():
    # Defensive: missing ``args`` becomes ``{}``; an entry with no ``id`` is
    # emitted as ``status="called"`` (no result to pair with).
    contents = [
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [{"name": "t", "args": None, "id": None}],
        },
    ]
    assert fold_trajectory(contents) == [
        {"name": "t", "args": {}, "result": None, "status": "called"},
    ]


# ---------------------------------------------------------------------------
# extract_tokens
# ---------------------------------------------------------------------------


def test_extract_tokens_reads_usage_metadata():
    usage = SimpleNamespace(prompt_token_count=3, candidates_token_count=5, total_token_count=8)
    response = SimpleNamespace(usage_metadata=usage)
    assert extract_tokens(response) == {
        "prompt_tokens": 3,
        "candidates_tokens": 5,
        "total_tokens": 8,
    }


def test_extract_tokens_falls_back_to_usage_attribute():
    usage = SimpleNamespace(prompt_token_count=1, candidates_token_count=2, total_token_count=3)
    # No ``usage_metadata``; the function should still find ``usage``.
    response = SimpleNamespace(usage=usage)
    assert extract_tokens(response) == {
        "prompt_tokens": 1,
        "candidates_tokens": 2,
        "total_tokens": 3,
    }


def test_extract_tokens_returns_empty_dict_when_no_usage():
    assert extract_tokens(SimpleNamespace()) == {}
    assert extract_tokens(None) == {}


def test_extract_tokens_defaults_missing_counts_to_zero():
    usage = SimpleNamespace(prompt_token_count=4)  # other counts unset
    response = SimpleNamespace(usage_metadata=usage)
    assert extract_tokens(response) == {
        "prompt_tokens": 4,
        "candidates_tokens": 0,
        "total_tokens": 0,
    }


# ---------------------------------------------------------------------------
# ApiAgent._execute — MCP-off path
# ---------------------------------------------------------------------------


def test_execute_runs_with_no_tools_when_target_unset(monkeypatch):
    """With no MCP server and no skills, the loop runs tool-less."""
    fake = _FakeLLMClient(
        [
            _Turn(
                text="done",
                usage=SimpleNamespace(
                    prompt_token_count=3,
                    candidates_token_count=5,
                    total_token_count=8,
                ),
            )
        ]
    )
    monkeypatch.setattr(agent_mod, "get_model", lambda *a, **kw: fake)

    agent = ApiAgent(AgentConfig())
    result = agent.run("hello")

    assert result.output == "done"
    assert result.trajectory == []
    assert result.tokens == {
        "prompt_tokens": 3,
        "candidates_tokens": 5,
        "total_tokens": 8,
    }
    assert result.errors == []
    # Caller-formats-tools: the agent must call format_tools on the (empty)
    # skill list before invoking the loop.
    assert fake.format_tools_calls == [[]]
    # The loop saw the pre-formatted tools sentinel, not the raw list.
    assert fake.calls[0]["tools"] == ("formatted", ())


def test_execute_passes_explicit_provider_and_model_to_get_model(monkeypatch):
    captured: dict[str, Any] = {}

    def fake_get_model(provider, model):
        captured["provider"] = provider
        captured["model"] = model
        return _FakeLLMClient([_Turn(text="ok")])

    monkeypatch.setattr(agent_mod, "get_model", fake_get_model)
    cfg = AgentConfig(provider="anthropic", model="claude-3-5")
    ApiAgent(cfg).run("p")
    assert captured == {"provider": "anthropic", "model": "claude-3-5"}


# ---------------------------------------------------------------------------
# ApiAgent._execute — MCP-on, trajectory folding & tools_used metadata
# ---------------------------------------------------------------------------


def test_execute_folds_assistant_tool_pairs_into_canonical_trajectory(monkeypatch):
    """End-to-end: an MCP tool turn followed by a finishing turn → one ToolCall."""
    fc = [{"name": "do_thing", "args": {"a": 1}, "id": "call-1"}]
    fake = _FakeLLMClient(
        [
            _Turn(text="working", calls=fc),
            _Turn(
                text="done",
                usage=SimpleNamespace(
                    prompt_token_count=10,
                    candidates_token_count=20,
                    total_token_count=30,
                ),
            ),
        ]
    )
    mcp_advertised = [SimpleNamespace(name="do_thing", description="d", inputSchema=None)]
    mcp = _FakeMCPClient(tools=mcp_advertised)
    monkeypatch.setattr(agent_mod, "get_model", lambda *a, **kw: fake)
    monkeypatch.setattr(agent_mod, "MCPClient", lambda _path: mcp)

    result = ApiAgent(AgentConfig(target="server")).run("ping")

    assert result.output == "done"
    assert result.trajectory == [
        {
            "name": "do_thing",
            "args": {"a": 1},
            "result": "mcp-result-of-do_thing",
            "status": "completed",
        },
    ]
    assert result.tokens == {
        "prompt_tokens": 10,
        "candidates_tokens": 20,
        "total_tokens": 30,
    }
    assert result.errors == []
    assert result.metadata["tools_used"] == ["do_thing"]
    # MCP session was entered & exited via the async-context-manager protocol.
    assert mcp.entered and mcp.exited
    # The agent passed the MCP-advertised tool through format_tools before
    # invoking the loop (caller-formats-tools contract).
    assert fake.format_tools_calls == [mcp_advertised]


# ---------------------------------------------------------------------------
# Dispatcher error handling
# ---------------------------------------------------------------------------


def test_execute_dispatch_error_lands_in_errors_and_continues(monkeypatch):
    """A tool call that raises must surface on errors, not crash the agent."""

    class _ExplodingMCP(_FakeMCPClient):
        async def call_tool(self, name: str, arguments: dict) -> Any:
            raise RuntimeError("kaboom")

    fc = [{"name": "boom", "args": {}, "id": "c1"}]
    fake = _FakeLLMClient(
        [
            _Turn(text="trying", calls=fc),
            _Turn(text="giving up"),
        ]
    )
    mcp = _ExplodingMCP(tools=[SimpleNamespace(name="boom", description="d", inputSchema=None)])
    monkeypatch.setattr(agent_mod, "get_model", lambda *a, **kw: fake)
    monkeypatch.setattr(agent_mod, "MCPClient", lambda _path: mcp)

    result = ApiAgent(AgentConfig(target="server")).run("ping")

    assert result.output == "giving up"
    assert any("Error calling tool boom" in e for e in result.errors)
    # The trajectory still records the failed call with ``status="error"`` so
    # the metrics layer can see the failure mode.
    assert result.trajectory == [
        {"name": "boom", "args": {}, "result": "Error: kaboom", "status": "error"},
    ]


def test_execute_records_missing_mcp_when_tool_requested_without_server(monkeypatch):
    """No MCP server, but the model still requests a tool → recorded, not crashed."""
    fc = [{"name": "ghost", "args": {}, "id": "c2"}]
    fake = _FakeLLMClient(
        [
            _Turn(text="requesting", calls=fc),
            _Turn(text="abandoned"),
        ]
    )
    monkeypatch.setattr(agent_mod, "get_model", lambda *a, **kw: fake)
    result = ApiAgent(AgentConfig()).run("p")  # no target -> no MCP

    assert any("no MCP server is configured" in e for e in result.errors)
    assert result.trajectory == [
        {
            "name": "ghost",
            "args": {},
            "result": (
                "Error: tool 'ghost' requested but no MCP server is configured for "
                "this agent."
            ),
            "status": "error",
        },
    ]


# ---------------------------------------------------------------------------
# Skills are independent of MCP
# ---------------------------------------------------------------------------


def test_execute_skills_discover_without_mcp(monkeypatch, tmp_path):
    """Skills must be loadable on the MCP-off path, not gated on MCP being on."""
    skill_dir = tmp_path / "skills"
    skill = skill_dir / "demo" / "SKILL.md"
    skill.parent.mkdir(parents=True)
    skill_body = '---\nname: "demo-skill"\ndescription: does things\n---\nbody\n'
    skill.write_text(skill_body)

    fc = [{"name": "skill_demo_skill", "args": {}, "id": "s1"}]
    fake = _FakeLLMClient(
        [
            _Turn(text="using skill", calls=fc),
            _Turn(text="done"),
        ]
    )
    monkeypatch.setattr(agent_mod, "get_model", lambda *a, **kw: fake)
    cfg = AgentConfig(skills_paths=(str(skill_dir),))  # NB: target is None
    result = ApiAgent(cfg).run("p")

    assert result.errors == []  # skill dispatch hit the file, not the MCP error
    # ``read_skill_file`` returns the whole file (frontmatter + body) so the
    # model can read either as it sees fit — matches the legacy semantic.
    assert result.trajectory == [
        {
            "name": "skill_demo_skill",
            "args": {},
            "result": skill_body,
            "status": "completed",
        },
    ]
    assert result.metadata["skills_loaded"] == ["demo-skill"]
    # format_tools received the synthetic skill descriptor — one entry.
    assert len(fake.format_tools_calls[0]) == 1
    assert fake.format_tools_calls[0][0].name == "skill_demo_skill"


def test_execute_no_skills_no_mcp_runs_tool_less(monkeypatch):
    """Empty skills + no target → loop seen no tools, no metadata noise."""
    fake = _FakeLLMClient([_Turn(text="hi")])
    monkeypatch.setattr(agent_mod, "get_model", lambda *a, **kw: fake)
    result = ApiAgent(AgentConfig()).run("p")
    assert result.output == "hi"
    assert "skills_loaded" not in result.metadata
    assert result.metadata["tools_used"] == []


# ---------------------------------------------------------------------------
# Surfaced model-construction errors / empty MCP target
# ---------------------------------------------------------------------------


def test_execute_returns_errored_on_empty_mcp_server_string(monkeypatch):
    """A whitespace-only ``target`` triggers ``MCPClient`` ValueError; the agent
    converts it to an errored result rather than crashing the harness."""
    fake = _FakeLLMClient([_Turn(text="never reached")])
    monkeypatch.setattr(agent_mod, "get_model", lambda *a, **kw: fake)

    # Real MCPClient: raises ValueError on __aenter__ when parts == []. We use
    # the real class here (no monkeypatch) to exercise the error path.
    result = ApiAgent(AgentConfig(target="   ")).run("p")
    assert result.has_errors()
    assert "MCP server_path is empty" in result.errors[0]
    # The base safety net was NOT used (we converted the ValueError ourselves).
    assert result.output.startswith("Error: ")


# ---------------------------------------------------------------------------
# No env-smuggling — neither BENCH_USE_MCP nor any direct env read
# ---------------------------------------------------------------------------


def test_execute_ignores_bench_use_mcp_env(monkeypatch):
    """Setting BENCH_USE_MCP must not change the agent's behavior.

    The MCP on/off gate is the presence of ``config.target``, not env.
    """
    monkeypatch.setenv("BENCH_USE_MCP", "false")
    fake = _FakeLLMClient([_Turn(text="ok")])
    monkeypatch.setattr(agent_mod, "get_model", lambda *a, **kw: fake)
    # No target → loop runs without MCP regardless of the env flag.
    result = ApiAgent(AgentConfig()).run("p")
    assert result.output == "ok"


def test_agent_source_has_no_bench_use_mcp_or_environ_reads():
    """Statically verify the agents/api source carries no env-smuggling.

    The conventions doc forbids agents from reading ``BENCH_USE_MCP`` (the
    harness threads the boolean instead) or any ``os.environ`` lookups inside
    the agent — capability/MCP on-off comes from ``AgentConfig``. This test
    walks the agents/api source AST and asserts no code (i.e. anything that is
    not a docstring or comment) references those names.
    """
    import ast
    import pathlib

    api_root = pathlib.Path(agent_mod.__file__).parent
    forbidden_names = {"get_env", "get_bool", "first_env", "require_env"}
    forbidden_strings = {"BENCH_USE_MCP"}

    for src in api_root.glob("*.py"):
        tree = ast.parse(src.read_text(), filename=str(src))

        for node in ast.walk(tree):
            # Bare names: ``get_env(...)`` / ``os.environ``.
            if isinstance(node, ast.Name) and node.id in forbidden_names:
                pytest.fail(
                    f"{src.name} references env-helper {node.id!r} at line "
                    f"{node.lineno}; config flows through AgentConfig"
                )
            # Attribute access: ``os.environ`` / ``os.getenv``.
            if isinstance(node, ast.Attribute):
                attr_chain = []
                cur: ast.AST | None = node
                while isinstance(cur, ast.Attribute):
                    attr_chain.append(cur.attr)
                    cur = cur.value
                if isinstance(cur, ast.Name):
                    attr_chain.append(cur.id)
                joined = ".".join(reversed(attr_chain))
                assert joined != "os.environ", (
                    f"{src.name} accesses os.environ at line {node.lineno}; "
                    "config flows through AgentConfig"
                )
                assert joined != "os.getenv", (
                    f"{src.name} calls os.getenv at line {node.lineno}; "
                    "config flows through AgentConfig"
                )
            # String literals: catch ``getenv("BENCH_USE_MCP")`` /
            # ``os.environ["BENCH_USE_MCP"]`` patterns even when wrapped in a
            # helper we didn't enumerate. Docstrings are still ``Str``/
            # ``Constant`` nodes but the parent statement is an ``Expr`` at the
            # head of a module/function/class — skip those.
            if (
                isinstance(node, ast.Constant)
                and isinstance(node.value, str)
                and node.value in forbidden_strings
            ):
                # Allow doc references — only reject when the same line names an
                # env accessor (``environ`` / ``getenv`` / ``get_env``).
                line_text = src.read_text().splitlines()[node.lineno - 1]
                accessor_hit = any(
                    a in line_text for a in ("environ", "getenv", "get_env")
                )
                assert not accessor_hit, (
                    f"{src.name} reads {node.value!r} via an env accessor "
                    f"at line {node.lineno}"
                )


def test_api_package_does_not_expose_legacy_context_or_system_instruction():
    """The PR2 contract drops the ``context``/``system_instruction`` grab-bag.

    No symbol or kwarg with that name should remain in the public surface.
    """
    import inspect

    sig = inspect.signature(ApiAgent.run)
    assert list(sig.parameters) == ["self", "prompt"], (
        "ApiAgent.run must take only (self, prompt); the legacy context/"
        "system_instruction kwargs are gone."
    )
    init_sig = inspect.signature(ApiAgent.__init__)
    # Inherited from AgentHarness — accepts config only.
    assert list(init_sig.parameters) == ["self", "config"]


@pytest.mark.parametrize("method_name", ["_execute"])
def test_execute_is_synchronous_and_safe_for_harness_invocation(method_name):
    """The harness calls ``run(prompt)`` synchronously; ``_execute`` must be sync too."""
    import inspect

    method = getattr(ApiAgent, method_name)
    assert not inspect.iscoroutinefunction(method), (
        f"ApiAgent.{method_name} must be synchronous so the harness can call "
        "agent.run(prompt) without managing an event loop itself."
    )
