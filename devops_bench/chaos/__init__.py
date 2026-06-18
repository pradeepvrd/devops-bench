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

"""Chaos injection: fault/trigger interfaces, registries, and the agent loop.

Importing this package is light: provider SDKs are loaded lazily by the models
layer only when :class:`ChaosAgent` constructs a client. Concrete faults are
imported here so they self-register in :data:`FAULTS`.
"""

from __future__ import annotations

from devops_bench.chaos.agent import ChaosAgent
from devops_bench.chaos.base import FAULTS, TRIGGERS, Fault, Trigger
from devops_bench.chaos.faults import generate_load  # noqa: F401 - registers the fault

__all__ = ["ChaosAgent", "Fault", "Trigger", "FAULTS", "TRIGGERS"]
