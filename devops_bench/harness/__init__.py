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

"""Orchestration engine: the harness that runs the evaluation pipeline.

The harness is the engine layer above all components, so it may import them.
Concrete agents and the metrics judge pull in heavy optional dependencies
(``deepeval``, provider SDKs); those are imported lazily by
:class:`~devops_bench.harness.default.DefaultHarness` only when a task runs, not
on package import.
"""

from __future__ import annotations

from devops_bench.harness.base import Harness
from devops_bench.harness.default import DefaultHarness
from devops_bench.harness.scenario import ScenarioManager

__all__ = ["Harness", "DefaultHarness", "ScenarioManager"]
