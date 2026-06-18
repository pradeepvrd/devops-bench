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

"""Agent-under-test interface and the agent-selection registry."""

from __future__ import annotations

from abc import ABC, abstractmethod

from devops_bench.core import Registry

__all__ = ["AgentHarness", "AGENTS"]

AGENTS: Registry[type[AgentHarness]] = Registry("agents")


class AgentHarness(ABC):
    """Abstract base for an agent driven during a benchmark run.

    A harness wraps one agent implementation (an external CLI binary, an API
    loop, ...) behind a single :meth:`run` call that returns the standardized
    result dict the evaluation pipeline consumes.

    Concrete subclasses live in sibling modules (e.g. ``agents.cli.gemini``) and
    self-register under a canonical key via ``@AGENTS.register(...)``.
    """

    @abstractmethod
    def run(self, prompt: str, context: dict | None = None) -> dict:
        """Execute the agent against ``prompt`` and return its trajectory.

        Args:
            prompt: Task prompt handed to the agent.
            context: Optional platform-agnostic context (cluster details, extra
                params) forwarded to the agent.

        Returns:
            The standardized result dict with keys ``output`` (str),
            ``latency`` (float seconds), ``tokens`` (dict), ``tools`` (dict),
            ``trajectory`` (list of tool-call dicts), and ``skills`` (list).
        """
