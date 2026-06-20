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

"""Unit tests for devops_bench.agents.config."""

from devops_bench.agents.config import AgentConfig


def test_default_construction_uses_safe_defaults():
    cfg = AgentConfig()
    assert cfg.model is None
    assert cfg.provider is None
    assert cfg.api_key is None
    assert cfg.target is None
    assert cfg.timeout_sec == 600.0
    assert cfg.allowed_tools == ()
    assert dict(cfg.extra_env) == {}


def test_from_env_maps_each_field():
    env = {
        "AGENT_MODEL": "gemini-2.5-pro",
        "AGENT_PROVIDER": "gemini",
        "AGENT_API_KEY": "secret",
        "AGENT_TARGET": "/usr/local/bin/gemini",
        "AGENT_TIMEOUT_SEC": "42",
        "AGENT_ALLOWED_TOOLS": "tool_a, tool_b ,tool_c",
    }
    cfg = AgentConfig.from_env(env)
    assert cfg.model == "gemini-2.5-pro"
    assert cfg.provider == "gemini"
    assert cfg.api_key == "secret"
    assert cfg.target == "/usr/local/bin/gemini"
    assert cfg.timeout_sec == 42.0
    assert cfg.allowed_tools == ("tool_a", "tool_b", "tool_c")


def test_from_env_treats_unset_as_defaults():
    cfg = AgentConfig.from_env({})
    assert cfg.model is None
    assert cfg.provider is None
    assert cfg.timeout_sec == 600.0
    assert cfg.allowed_tools == ()


def test_from_env_blank_allowed_tools_yields_empty_tuple():
    cfg = AgentConfig.from_env({"AGENT_ALLOWED_TOOLS": ""})
    assert cfg.allowed_tools == ()
    cfg = AgentConfig.from_env({"AGENT_ALLOWED_TOOLS": " , , "})
    assert cfg.allowed_tools == ()
