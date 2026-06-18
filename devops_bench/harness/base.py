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

"""Harness interface: the engine that runs the end-to-end evaluation pipeline."""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any

from devops_bench.core import RunContext

__all__ = ["Harness"]


class Harness(ABC):
    """Abstract engine orchestrating a full benchmark evaluation.

    A harness sits above every component (deployers, agents, chaos, verification,
    metrics) and threads them together for each task: provision infrastructure,
    optionally start a background chaos scenario, run the agent under test,
    collect artifacts, tear down, then score and report. It owns the
    :class:`~devops_bench.core.RunContext` carried across these phases.

    Concrete harnesses implement :meth:`run` to execute a batch of tasks;
    :meth:`make_context` is a helper for building the per-task context.
    """

    @abstractmethod
    def run(self, eval_data: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Run the full pipeline over a batch of tasks.

        Args:
            eval_data: Loaded task specs, each with at least ``name`` and
                ``input`` and optionally ``infrastructure`` / ``chaos_spec`` /
                ``verification_spec`` / ``expected_output``.

        Returns:
            The detailed per-task result dicts, scored in place.
        """

    def make_context(
        self, item: dict[str, Any], cluster: Any | None = None
    ) -> RunContext:
        """Build the per-task run context carried across pipeline phases.

        Args:
            item: The task spec being evaluated.
            cluster: Provisioned cluster details, if any.

        Returns:
            A :class:`~devops_bench.core.RunContext` seeded with task metadata.
        """
        return RunContext(
            task_id=str(item.get("task_id", item.get("name", ""))),
            task_name=item.get("name", ""),
            cluster=cluster,
        )
