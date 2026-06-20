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

"""Rules capability: binding data + agent-side Protocol/mixin.

:class:`AgentRules` carries the operator brief that used to ride as
``system_instruction`` — the "you are a DevOps engineer..." preamble — but
modeled as a **binding** so it is identical across agents for fairness and
delivered via each agent's native mechanism (``GEMINI.md`` for Gemini, the
``system`` parameter for the API agent, etc.; PR3 only delivers whatever
text it is given).

Per the handoff (§5.3), the orchestrator resolves the actual text against
``capabilities`` (the "you MUST use your tools" clause is only valid when
tools are granted). This module owns no resolution — only the data type and
the structural Protocol agents implement to advertise the capability.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol, runtime_checkable

__all__ = ["AgentRules", "SupportsRules", "RulesMixin"]


@dataclass(frozen=True)
class AgentRules:
    """The operator brief delivered to an agent at run start.

    Attributes:
        text: Free-form rules / system-prompt text. An empty string means "no
            preamble" (the agent runs with only the task prompt) — match the
            interim PR1/PR2 behavior so a default :class:`AgentRules` is
            indistinguishable from "no rules".
    """

    text: str = ""


@runtime_checkable
class SupportsRules(Protocol):
    """Structural marker for an agent that can carry an :class:`AgentRules` text.

    Every concrete agent in PR3 supports rules (each CLI / API transport has
    a native delivery mechanism), but the Protocol still exists so the
    orchestrator can negotiate uniformly across the three capabilities.
    """

    rules: AgentRules


@dataclass
class RulesMixin:
    """Default-implementation mixin granting :class:`SupportsRules`.

    Attributes:
        rules: The rules binding granted for the current run; defaults to an
            empty :class:`AgentRules` (no preamble).
    """

    rules: AgentRules = field(default_factory=AgentRules)
