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

"""JSON Schema emission and node validation for verification specs.

These helpers are the authoring contract: they let task authors generate an
editor schema and validate a single spec literal without spinning up the
runner. The schema is derived from each verifier model registered in
:data:`VERIFIERS` and stays in lock-step with the registry — registering a new
verifier extends the schema without any edit here.
"""

from __future__ import annotations

from typing import Any

from pydantic import ValidationError

from devops_bench.verification.registry import VERIFIERS
from devops_bench.verification.spec import VerificationNode, parse_node

# Importing ``spec`` runs the leaf/compound registrations on first use.
# ``parse_node`` is the registry-driven counterpart of the legacy
# ``VerificationSpec(data).root`` path.

__all__ = ["json_schema", "validate_spec"]


def json_schema() -> dict[str, Any]:
    """Return the JSON Schema for a verification spec.

    The schema is an ``anyOf`` over every model registered in :data:`VERIFIERS`,
    discriminated by each model's ``type`` literal. It is regenerated from the
    registry on every call so newly registered verifiers appear automatically.

    Returns:
        A JSON-serializable mapping describing the spec union.
    """
    members = list(VERIFIERS.values())
    return {
        "title": "VerificationSpec",
        "anyOf": [m.model_json_schema() for m in members],
        "discriminator": {"propertyName": "type"},
    }


def validate_spec(data: Any) -> VerificationNode:
    """Validate a raw mapping against the verifier registry.

    Args:
        data: A mapping (or already-parsed node) authored in a task file.

    Returns:
        The concrete leaf or compound node selected by the ``type`` discriminator.

    Raises:
        pydantic.ValidationError: If ``data`` does not match a registered
            verifier (or its target model's own validation fails).
    """
    try:
        return parse_node(data)
    except ValidationError:
        raise
