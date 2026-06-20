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

These helpers are the Phase-2B authoring contract: they let task authors
generate an editor schema and validate a single spec literal without spinning
up the runner. The schema is derived from the pydantic
:class:`VerificationSpec` model and stays in lock-step with the union.
"""

from __future__ import annotations

from typing import Any

from pydantic import ValidationError

from devops_bench.verification.spec import VerificationNode, VerificationSpec

__all__ = ["json_schema", "validate_spec"]


def json_schema() -> dict[str, Any]:
    """Return the JSON Schema for a verification spec.

    Returns:
        A JSON-serializable mapping derived from the pydantic
        :class:`VerificationSpec` model.
    """
    return VerificationSpec.model_json_schema()


def validate_spec(data: Any) -> VerificationNode:
    """Validate a raw mapping against the verification spec union.

    Args:
        data: A mapping (or already-parsed node) authored in a task file.

    Returns:
        The concrete leaf or compound node selected by the ``type`` discriminator.

    Raises:
        pydantic.ValidationError: If ``data`` does not match any union member.
    """
    try:
        return VerificationSpec(data).root
    except ValidationError:
        raise
