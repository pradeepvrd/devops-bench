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

"""Discriminated-union schema for verification specs.

A spec is one of the type-tagged leaves (e.g. ``pod_healthy``,
``scaling_complete``) or a compound node (``sequence``, ``parallel``). The
``name`` field is metadata for result labeling only; recursion is explicit via
the compound nodes' ``checks`` list. Bare lists or dicts as spec nodes are
rejected — authoring is explicit-``type``-only.

The hand-maintained ``VerificationNode`` union is the Phase-A shape (matches
pydantic's native discriminator errors byte-for-byte). It is structured so a
later registry-driven ``parse_node`` (Wave 2 metrics PR) can swap *only* the
parsing without reshaping the runner's ``isinstance`` dispatch on
``SequenceSpec`` / ``ParallelSpec``.
"""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, Field, RootModel

from devops_bench.verification.verifiers.pod_healthy import PodHealthyVerifier
from devops_bench.verification.verifiers.scaling_complete import ScalingCompleteVerifier

__all__ = [
    "ParallelSpec",
    "SequenceSpec",
    "VerificationNode",
    "VerificationSpec",
]


class SequenceSpec(BaseModel):
    """Ordered, fail-fast group: members run in sequence; stop at first failure.

    Attributes:
        type: Discriminator literal, always ``"sequence"``.
        name: Optional label echoed onto the result; metadata, never structural.
        checks: Ordered child nodes; each is itself a :data:`VerificationNode`.
    """

    type: Literal["sequence"]
    name: str | None = None
    checks: list[VerificationNode]


class ParallelSpec(BaseModel):
    """Independent group: members run concurrently; all must pass.

    Attributes:
        type: Discriminator literal, always ``"parallel"``.
        name: Optional label echoed onto the result; metadata, never structural.
        checks: Sibling child nodes; each is itself a :data:`VerificationNode`.
    """

    type: Literal["parallel"]
    name: str | None = None
    checks: list[VerificationNode]


# Leaves and compounds live in one union, keyed on ``type``. A bare leaf is a
# valid whole spec (it is a union member) — single checks need no wrapping.
VerificationNode = Annotated[
    PodHealthyVerifier | ScalingCompleteVerifier | SequenceSpec | ParallelSpec,
    Field(discriminator="type"),
]


class VerificationSpec(RootModel[VerificationNode]):
    """Entry-point wrapper; ``VerificationSpec(data).root`` yields a concrete node.

    Example:
        >>> spec = VerificationSpec({"type": "pod_healthy", "selector": "app=web"})
        >>> spec.root.type
        'pod_healthy'
    """


SequenceSpec.model_rebuild()
ParallelSpec.model_rebuild()
VerificationSpec.model_rebuild()
