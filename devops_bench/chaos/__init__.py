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

Importing this package is intentionally light: no provider SDKs, no
``ChaosAgent``, no concrete fault or trigger. Concretes register lazily — they
are imported at call time by the consumer (today, by importing
:mod:`devops_bench.chaos.spec`, which is the explicit entry point for parsing).
Mirrors :mod:`devops_bench.verification` and :mod:`devops_bench.models`'s lazy
loading discipline (CONVENTIONS §8).
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
