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

"""Agent capabilities: binding data + structural Protocols + mixins.

Three orthogonal axes:

* **MCP** — :class:`McpBinding` describes one MCP server (launch command +
  tool names). The :class:`SupportsMcp` Protocol marks an agent that can drive
  MCP; :class:`McpMixin` is the trivial implementation.
* **Skills** — :class:`SkillBinding` carries local ``SKILL.md`` paths the
  agent loads. Independent of MCP.
* **Rules** — :class:`AgentRules` carries the operator brief text. Delivered
  via each agent's native mechanism.

The three are bundled on :class:`AgentCapabilities`, which lives on
:class:`~devops_bench.agents.config.AgentConfig.capabilities`. The orchestrator
constructs the bundle from a benchmark catalog (resolving the GKE MCP binding,
the GKE skill paths, and arm-aware rules text). Agent code never references
"GKE" — the bindings are plain values.

Importing this package pulls **no** provider SDK / ``mcp`` / ``deepeval`` —
only stdlib (CONVENTIONS §8).
"""

from __future__ import annotations

from devops_bench.agents.capabilities.aggregate import AgentCapabilities
from devops_bench.agents.capabilities.mcp import McpBinding, McpMixin, SupportsMcp
from devops_bench.agents.capabilities.rules import AgentRules, RulesMixin, SupportsRules
from devops_bench.agents.capabilities.skills import (
    SkillBinding,
    SkillsMixin,
    SupportsSkills,
)

__all__ = [
    "AgentCapabilities",
    "AgentRules",
    "McpBinding",
    "McpMixin",
    "RulesMixin",
    "SkillBinding",
    "SkillsMixin",
    "SupportsMcp",
    "SupportsRules",
    "SupportsSkills",
]
