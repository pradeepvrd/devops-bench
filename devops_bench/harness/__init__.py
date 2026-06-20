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

"""Orchestration engine: the harness that wires every component into one pipeline.

``import devops_bench.harness`` stays light: it pulls only the :class:`Harness`
abstract base and the :class:`ResultReporter`. The default implementation
(:class:`DefaultHarness`) and the background scenario manager
(:class:`ScenarioManager`) are resolved lazily on first attribute access so the
package can be imported on a host without ``deepeval`` / provider SDKs / ``mcp``
/ fortio installed (CONVENTIONS.md §8).

The harness is the sole layer permitted to *wire* components, and it does so by
**consuming registries** (``AGENTS``, ``FAULTS``, ``TRIGGERS``, ``VERIFIERS``,
``METRICS``) — never by mirroring module paths (CONVENTIONS.md §2).
"""

from __future__ import annotations

import importlib
from typing import TYPE_CHECKING, Any

from devops_bench.harness.base import Harness
from devops_bench.harness.reporter import ResultReporter

__all__ = ["DefaultHarness", "Harness", "ResultReporter", "ScenarioManager"]

# Public name -> defining submodule, resolved lazily in ``__getattr__`` so a
# bare ``import devops_bench.harness`` does not pull the metrics judge / chaos
# agent transitively. Only ``Harness`` (above) is eagerly imported because it
# is the abstract base downstream callers most often type-hint against.
_EXPORTS = {
    "DefaultHarness": "default",
    "ScenarioManager": "scenario",
}


if TYPE_CHECKING:  # pragma: no cover - typing-only imports
    from devops_bench.harness.default import DefaultHarness
    from devops_bench.harness.scenario import ScenarioManager


def __getattr__(name: str) -> Any:
    """Lazily import and return a public harness symbol on first access."""
    module_name = _EXPORTS.get(name)
    if module_name is None:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    module = importlib.import_module(f"{__name__}.{module_name}")
    return getattr(module, name)


def __dir__() -> list[str]:
    return sorted(__all__)
