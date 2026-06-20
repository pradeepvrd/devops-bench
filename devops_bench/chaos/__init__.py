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

The package's import surface stays minimal — ``Fault``, ``Trigger``,
``ChaosResult``, ``FAULTS``, ``TRIGGERS``, ``ChaosSpec``. ``ChaosAgent`` is
intentionally **not** exported.

What this package *does* load on import: the concrete fault / trigger modules
that participate in :class:`ChaosSpec`'s discriminated union
(:class:`~devops_bench.chaos.faults.generate_load.GenerateLoadFault`,
:class:`~devops_bench.chaos.triggers.time_delay.TimeTrigger`), and transitively
the agent module they construct at injection time. This is required for
Phase-A union parsing (CONVENTIONS §4) and matches verification's pattern.

What it does **not** load: provider SDKs (``anthropic``, ``google.genai``,
``openai``, ``ollama``), ``deepeval``, ``mcp``, or the fortio binary — all of
those stay strictly function-local and only fire when a fault actually injects
(CONVENTIONS §8). The lightweight-import guard in ``tests/unit/chaos`` enforces
this invariant.
"""

from __future__ import annotations

from devops_bench.chaos.base import FAULTS, TRIGGERS, ChaosResult, Fault, Trigger
from devops_bench.chaos.spec import ChaosSpec

__all__ = [
    "ChaosResult",
    "ChaosSpec",
    "FAULTS",
    "Fault",
    "TRIGGERS",
    "Trigger",
]
