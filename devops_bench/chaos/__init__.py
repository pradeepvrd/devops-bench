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

"""Chaos injection: fault/trigger interfaces, registries, and the typed spec.

The package's import surface is intentionally small — ``Fault``, ``Trigger``,
``ChaosResult``, ``FAULTS``, ``TRIGGERS``, ``ChaosSpec``. ``ChaosAgent`` is
**not** exported (and not imported on package import).

Phase 4 (CONVENTIONS §4 "Phase-A → Phase-4 swap"): :class:`ChaosSpec` parses
through the :data:`FAULTS` / :data:`TRIGGERS` registries — there is no static
``Annotated[Union]``. Concrete fault / trigger modules are loaded **lazily**
on the first parse (and within :meth:`Fault.inject` for the agent + models
chain). Importing this package therefore stays strictly light:

- pulls: ``chaos.{__init__, base, registry, spec}`` and ``core.*``
- does NOT pull: ``chaos.agent``, ``chaos.faults.*``, ``chaos.triggers.*``,
  ``devops_bench.models.*``, provider SDKs (``anthropic``, ``google.genai``,
  ``openai``, ``ollama``), ``deepeval``, ``mcp``, or the fortio binary.

The lightweight-import guard in ``tests/unit/chaos/test_package_import.py``
enforces this invariant.
"""

from __future__ import annotations

from devops_bench.chaos.base import ChaosResult, Fault, Trigger
from devops_bench.chaos.registry import FAULTS, TRIGGERS
from devops_bench.chaos.spec import ChaosSpec

__all__ = [
    "ChaosResult",
    "ChaosSpec",
    "FAULTS",
    "Fault",
    "TRIGGERS",
    "Trigger",
]
