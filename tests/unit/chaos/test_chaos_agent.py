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
    mock_cmd = mocker.patch.object(
        agent_module, "run_chaos_command", return_value="Stdout:\nok\nStderr:\n"
    )
    client = _make_client(
        mocker,
        call_batches=[
            [{"name": "run_command", "args": {"command": "fortio load x"}, "id": "c1"}],
            [],
        ],
        texts=["", "all done"],
    )

    event = threading.Event()
    chaos_agent = ChaosAgent(chaos_active_event=event, client=client)
    result = chaos_agent.run("do chaos")

    assert result == "all done"
    mock_cmd.assert_called_once_with("fortio load x", event)
    # Two model turns; tool result fed back between them.
    assert client.generate_content.await_count == 2
    client.format_tools.assert_called_once_with([RUN_COMMAND_TOOL])


def test_run_finishes_immediately_without_tool_calls(mocker):
    mock_cmd = mocker.patch.object(agent_module, "run_chaos_command")
    client = _make_client(mocker, call_batches=[[]], texts=["nothing to do"])

    chaos_agent = ChaosAgent(client=client)
    result = chaos_agent.run("noop")

    assert result == "nothing to do"
    mock_cmd.assert_not_called()


def test_run_stops_at_turn_limit_retains_last_text(mocker):
    mocker.patch.object(agent_module, "run_chaos_command", return_value="out")
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

    chaos_agent = ChaosAgent(client=client)
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
