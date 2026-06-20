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

"""Single extension axes for chaos fault and trigger nodes.

Each concrete fault and trigger registers itself by its ``type`` literal here.
The Phase-4 spec parser in :mod:`devops_bench.chaos.spec` consults these
registries instead of a hand-maintained pydantic ``Union``, so a new fault or
trigger needs no central edit. Mirrors
:data:`devops_bench.verification.registry.VERIFIERS`.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from devops_bench.core import Registry

if TYPE_CHECKING:  # pragma: no cover - typing-only import
    from devops_bench.chaos.base import Fault, Trigger

__all__ = ["FAULTS", "TRIGGERS"]

#: Registry of concrete :class:`Fault` subclasses, keyed by their ``type``.
#: ``entry_point_group`` lets external packages register a fault without
#: touching this tree.
FAULTS: Registry[type[Fault]] = Registry(
    "faults", entry_point_group="devops_bench.faults"
)

#: Registry of concrete :class:`Trigger` subclasses, keyed by their ``type``.
TRIGGERS: Registry[type[Trigger]] = Registry(
    "triggers", entry_point_group="devops_bench.triggers"
)
