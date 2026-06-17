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

"""Tests for the Gemini (google-genai) adapter."""

from __future__ import annotations

import asyncio
import base64
import os
from types import SimpleNamespace
from unittest.mock import AsyncMock

from devops_bench.models import google
from devops_bench.models.google import GeminiClientAdapter, filter_schema_for_gemini


def _make_tool(name, description, input_schema):
    return SimpleNamespace(name=name, description=description, inputSchema=input_schema)


# --- filter_schema_for_gemini -------------------------------------------------


def test_filter_schema_upper_cases_type_and_drops_unsupported():
    schema = {
        "type": "object",
        "title": "ignored",
        "properties": {
            "count": {"type": "integer", "description": "a count"},
            "name": {"type": ["string", "null"]},
        },
        "required": ["count"],
    }

    result = filter_schema_for_gemini(schema)

    assert result["type"] == "OBJECT"
    assert "title" not in result
    assert result["properties"]["count"] == {"type": "INTEGER", "description": "a count"}
    # Nullable union collapses to nullable + the non-null type.
    assert result["properties"]["name"] == {"type": "STRING", "nullable": True}
    assert result["required"] == ["count"]


def test_filter_schema_bool_inputs():
    assert filter_schema_for_gemini(True) == {}
    assert filter_schema_for_gemini(False) is None


# --- client selection by env --------------------------------------------------


def test_client_selection_api_key(mocker):
    client_cls = mocker.patch.object(google.genai, "Client")
    mocker.patch.dict(os.environ, {"AGENT_API_KEY": "k", "GCP_PROJECT_ID": "p"}, clear=True)

    GeminiClientAdapter()

    client_cls.assert_called_once_with(api_key="k")


def test_client_selection_vertex(mocker):
    client_cls = mocker.patch.object(google.genai, "Client")
    mocker.patch.dict(
        os.environ, {"GCP_PROJECT_ID": "proj", "GCP_VERTEX_LOCATION": "europe-west1"}, clear=True
    )

    GeminiClientAdapter()

    client_cls.assert_called_once_with(vertexai=True, project="proj", location="europe-west1")


def test_client_selection_default(mocker):
    client_cls = mocker.patch.object(google.genai, "Client")
    mocker.patch.dict(os.environ, {}, clear=True)

    adapter = GeminiClientAdapter()

    client_cls.assert_called_once_with()
    assert adapter.model_name == "gemini-3.1-pro-preview"


# --- format_tools -------------------------------------------------------------


def test_format_tools_applies_filter(mocker):
    mocker.patch.object(google.genai, "Client")
    adapter = GeminiClientAdapter()
    tool = _make_tool("do_thing", "does a thing", {"type": "object", "title": "drop"})

    result = adapter.format_tools([tool])

    decl = result.function_declarations[0]
    assert decl.name == "do_thing"
    assert decl.description == "does a thing"
    # filter_schema_for_gemini upper-cased the type and dropped unsupported keys.
    assert decl.parameters.type == "OBJECT"


# --- extract_function_calls ---------------------------------------------------


def test_extract_function_calls(mocker):
    mocker.patch.object(google.genai, "Client")
    adapter = GeminiClientAdapter()

    part = SimpleNamespace(
        function_call=SimpleNamespace(name="fc", args={"x": 1}),
        thought_signature=b"sig",
    )
    response = SimpleNamespace(candidates=[SimpleNamespace(content=SimpleNamespace(parts=[part]))])

    calls = adapter.extract_function_calls(response)

    assert calls == [
        {
            "name": "fc",
            "args": {"x": 1},
            "id": None,
            "thought_signature": base64.b64encode(b"sig").decode("utf-8"),
        }
    ]


def test_extract_function_calls_no_candidates(mocker):
    mocker.patch.object(google.genai, "Client")
    adapter = GeminiClientAdapter()

    assert adapter.extract_function_calls(SimpleNamespace(candidates=None)) == []


# --- get_text_content ---------------------------------------------------------


def test_get_text_content(mocker):
    mocker.patch.object(google.genai, "Client")
    adapter = GeminiClientAdapter()

    assert adapter.get_text_content(SimpleNamespace(text="hi")) == "hi"
    assert adapter.get_text_content(SimpleNamespace(text=None)) == ""


# --- generate_content ---------------------------------------------------------


def test_generate_content_invokes_sdk(mocker):
    client = mocker.patch.object(google.genai, "Client").return_value
    generate = AsyncMock(return_value="resp")
    client.aio.models.generate_content = generate

    adapter = GeminiClientAdapter()
    tools = adapter.format_tools([_make_tool("t", "d", {"type": "object", "properties": {}})])

    result = asyncio.run(
        adapter.generate_content([{"role": "user", "content": "hello"}], tools, "be helpful")
    )

    assert result == "resp"
    generate.assert_awaited_once()
    kwargs = generate.await_args.kwargs
    assert kwargs["model"] == adapter.model_name
    assert kwargs["contents"]  # converted gemini messages
