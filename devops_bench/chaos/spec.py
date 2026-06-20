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

"""Discriminated-union schema for chaos specs.

A chaos entry has a :class:`~devops_bench.chaos.base.Trigger`, a
:class:`~devops_bench.chaos.base.Fault` (action), and an optional ``verify``
key that *references* a verification entry by name. The reference is **opaque
to chaos**: chaos never constructs or imports a :mod:`verification` node —
the harness resolves the key against the verification registry (CONVENTIONS
§4). This keeps chaos and verification as true Layer-2 siblings.

The :data:`ChaosAction` / :data:`ChaosTrigger` unions are hand-maintained in
Phase A (matches pydantic's native discriminator errors byte-for-byte across
verification and chaos). A later phase swaps the parsing to be registry-driven
without reshaping the runner's dispatch — see CONVENTIONS §4.
"""

from __future__ import annotations

from typing import Annotated

from pydantic import AliasChoices, BaseModel, ConfigDict, Field

from devops_bench.chaos.faults.generate_load import GenerateLoadFault
from devops_bench.chaos.triggers.time_delay import TimeTrigger

__all__ = [
    "ChaosAction",
    "ChaosSpec",
    "ChaosTrigger",
]

# Leaves live in one discriminated union, keyed on ``type``. A bare leaf is a
# valid action / trigger — the discriminator does the dispatch.
ChaosAction = Annotated[GenerateLoadFault, Field(discriminator="type")]
ChaosTrigger = Annotated[TimeTrigger, Field(discriminator="type")]


class ChaosSpec(BaseModel):
    """One authored chaos entry: a trigger, an action, and an optional verify ref.

    The :attr:`verify` field is a plain string key naming a verification entry;
    it is **never** an inline verification node. The harness resolves the key
    against its verification registry. The legacy task-file field
    ``verification`` is accepted as an alias so the real
    ``complextasks/optimize-scale/task.yaml`` spec parses unchanged ahead of
    Phase B's task-file migration.

    Attributes:
        name: Human-readable label echoed onto the chaos report.
        trigger: ``type``-tagged firing condition (e.g. :class:`TimeTrigger`).
        action: ``type``-tagged disruption (e.g. :class:`GenerateLoadFault`).
        verify: Optional verification-key reference; ``None`` skips post-fault
            verification. Accepts the ``verification`` alias for the legacy
            authored shape.
    """

    # ``populate_by_name`` lets the canonical ``verify`` field coexist with the
    # legacy ``verification`` author alias. ``extra="forbid"`` keeps drift loud.
    model_config = ConfigDict(populate_by_name=True, extra="forbid")

    name: str = "Planned Disruption"
    trigger: ChaosTrigger
    action: ChaosAction
    verify: str | None = Field(
        default=None,
        validation_alias=AliasChoices("verify", "verification"),
    )
