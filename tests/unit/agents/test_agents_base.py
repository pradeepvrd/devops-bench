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

"""Unit tests for devops_bench.agents.base."""

from __future__ import annotations

import pytest

from devops_bench.agents import AGENTS, AgentHarness
from devops_bench.core import Registry


def test_agents_registry_is_registry_instance():
    assert isinstance(AGENTS, Registry)
    assert AGENTS.name == "agents"


def test_agent_harness_is_abstract():
    with pytest.raises(TypeError):
        AgentHarness()  # abstract run() prevents instantiation


def test_concrete_subclass_runs_and_registers():
    @AGENTS.register("fake-test-agent")
    class FakeAgent(AgentHarness):
        def run(self, prompt, context=None):
            return {
                "output": prompt,
                "latency": 0.0,
                "tokens": {},
                "tools": {},
                "trajectory": [],
                "skills": [],
            }

    assert AGENTS.get("fake-test-agent") is FakeAgent
    result = FakeAgent().run("hello")
    assert result["output"] == "hello"
    assert set(result) == {"output", "latency", "tokens", "tools", "trajectory", "skills"}


def test_cli_agents_register_on_import():
    # Importing the concrete modules self-registers them under their keys.
    from devops_bench.agents.cli import gemini, openclaw

    assert AGENTS.get("gemini") is gemini.GeminiCliAgent
    assert AGENTS.get("openclaw") is openclaw.OpenClawAgent
