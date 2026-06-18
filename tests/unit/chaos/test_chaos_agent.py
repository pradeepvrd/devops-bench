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

"""Tests for the model-agnostic ChaosAgent loop."""

from __future__ import annotations

import threading

from devops_bench.chaos import agent as agent_module
from devops_bench.chaos.agent import RUN_COMMAND_TOOL, ChaosAgent


def _make_client(mocker, *, call_batches, texts):
    """Build a fake LLMClient that yields the given tool-call batches/texts."""
    client = mocker.MagicMock()
    client.format_tools.return_value = "FORMATTED_TOOLS"
    client.generate_content = mocker.AsyncMock(
        side_effect=[f"resp{i}" for i in range(len(call_batches))]
    )
    client.get_text_content.side_effect = texts
    client.extract_function_calls.side_effect = call_batches
    return client


def test_agent_selects_model_from_config(mocker):
    fake_client = mocker.MagicMock()
    get_model = mocker.patch.object(agent_module, "get_model", return_value=fake_client)
    mocker.patch.object(agent_module, "first_env", side_effect=["my-provider", "my-model"])

    chaos_agent = ChaosAgent()

    get_model.assert_called_once_with(provider="my-provider", model_name="my-model")
    assert chaos_agent._client is fake_client


def test_run_executes_tool_then_finishes(mocker):
    mock_cmd = mocker.MagicMock(return_value="Stdout:\nok\nStderr:\n")
    client = _make_client(
        mocker,
        call_batches=[
            [{"name": "run_command", "args": {"command": "fortio load x"}, "id": "c1"}],
            [],
        ],
        texts=["", "all done"],
    )

    event = threading.Event()
    chaos_agent = ChaosAgent(chaos_active_event=event, client=client, tool_handler=mock_cmd)
    result = chaos_agent.run("do chaos")

    assert result == "all done"
    mock_cmd.assert_called_once_with("fortio load x", event)
    # Two model turns; tool result fed back between them.
    assert client.generate_content.await_count == 2
    client.format_tools.assert_called_once_with([RUN_COMMAND_TOOL])


def test_run_finishes_immediately_without_tool_calls(mocker):
    mock_cmd = mocker.MagicMock()
    client = _make_client(mocker, call_batches=[[]], texts=["nothing to do"])

    chaos_agent = ChaosAgent(client=client, tool_handler=mock_cmd)
    result = chaos_agent.run("noop")

    assert result == "nothing to do"
    mock_cmd.assert_not_called()


def test_run_stops_at_turn_limit_retains_last_text(mocker):
    mocker.patch.object(agent_module, "_MAX_TURNS", 3)
    # Always returns a tool call so the loop must hit the cap; the model also
    # emits text on every turn, which must be retained even though the final
    # turn still carries a tool call.
    client = mocker.MagicMock()
    client.format_tools.return_value = "T"
    client.generate_content = mocker.AsyncMock(return_value="resp")
    client.get_text_content.return_value = "still working"
    client.extract_function_calls.return_value = [
        {"name": "run_command", "args": {"command": "fortio load x"}, "id": "c"}
    ]

    chaos_agent = ChaosAgent(client=client, tool_handler=mocker.MagicMock(return_value="out"))
    result = chaos_agent.run("loop forever")

    # Final-turn text is preserved despite the accompanying tool call.
    assert result == "still working"
    assert client.generate_content.await_count == 3


def test_unknown_tool_returns_error(mocker):
    client = mocker.MagicMock()
    chaos_agent = ChaosAgent(client=client)

    result = chaos_agent._execute_tool("mystery", {})

    assert result.startswith("Error: unknown tool")


def test_non_dict_args_returns_error(mocker):
    client = mocker.MagicMock()
    chaos_agent = ChaosAgent(client=client)

    for bad_args in (None, "fortio load x", ["fortio"], 42):
        result = chaos_agent._execute_tool("run_command", bad_args)
        assert result == "Error: tool args must be an object"


# --- URL flow (#5) ----------------------------------------------------------


def test_target_url_from_spec_reads_service_url():
    spec = {"type": "generate_load", "target": {"service_url": "http://svc:9000"}}
    assert agent_module.target_url_from_spec(spec) == "http://svc:9000"


def test_target_url_from_spec_falls_back_to_default():
    # Missing target, malformed target, blank URL, and non-dict all fall back.
    assert agent_module.target_url_from_spec({}) == "http://localhost:8080"
    assert agent_module.target_url_from_spec({"target": "nope"}) == "http://localhost:8080"
    assert (
        agent_module.target_url_from_spec({"target": {"service_url": "  "}})
        == "http://localhost:8080"
    )
    assert agent_module.target_url_from_spec(None) == "http://localhost:8080"


def test_build_system_instruction_injects_url():
    instruction = agent_module.build_system_instruction("http://svc:9000")
    assert "http://svc:9000" in instruction
    # The hardcoded default is not present when a custom URL is supplied.
    assert "localhost:8080" not in instruction


def test_default_system_instruction_uses_default_url():
    assert "http://localhost:8080" in agent_module.SYSTEM_INSTRUCTION


# --- constructor dependency injection (#6) + custom tools/instruction --------


def test_run_uses_injected_system_instruction_and_tools(mocker):
    client = _make_client(mocker, call_batches=[[]], texts=["done"])
    custom_tools = [RUN_COMMAND_TOOL, RUN_COMMAND_TOOL]

    chaos_agent = ChaosAgent(
        client=client,
        system_instruction="CUSTOM SYS",
        tools=custom_tools,
        tool_handler=mocker.MagicMock(),
    )
    chaos_agent.run("go")

    client.format_tools.assert_called_once_with(custom_tools)
    # The injected system instruction is passed through to generate_content.
    assert client.generate_content.await_args.args[2] == "CUSTOM SYS"


# --- handler decoupling (#7) ------------------------------------------------


def test_agent_module_has_no_top_level_fault_import():
    # The orchestrator must not couple to the concrete fault at module load.
    assert not hasattr(agent_module, "run_chaos_command")


def test_default_tool_handler_is_run_chaos_command(mocker):
    # With no injected handler, the ctor lazily binds the real fault handler.
    from devops_bench.chaos.faults.generate_load import run_chaos_command

    chaos_agent = ChaosAgent(client=mocker.MagicMock())
    assert chaos_agent._tool_handler is run_chaos_command
