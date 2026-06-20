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

"""Single extension axis for verifier spec nodes.

Each leaf verifier and each compound spec (``sequence`` / ``parallel``) registers
itself by its ``type`` literal here. The spec parser in
:mod:`devops_bench.verification.spec` consults this registry instead of a
hand-maintained pydantic ``Union``, so new verifiers need no central edit.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from devops_bench.core import Registry

if TYPE_CHECKING:  # pragma: no cover - typing-only import
    from pydantic import BaseModel

__all__ = ["VERIFIERS"]

# Registry keyed by the ``type`` discriminator literal. Entry-point discovery
# lets external packages register a verifier without touching this tree.
VERIFIERS: Registry[type[BaseModel]] = Registry(
    "verifiers", entry_point_group="devops_bench.verifiers"
)
