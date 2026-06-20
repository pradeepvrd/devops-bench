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

"""JSON Schema emission and entry validation for chaos specs.

These helpers are the Phase-A authoring contract: they let task authors
generate an editor schema and validate a single chaos entry without spinning
up the harness. The schema is derived from the pydantic :class:`ChaosSpec`
model and stays in lock-step with the union.
"""

from __future__ import annotations

from typing import Any

from pydantic import ValidationError

from devops_bench.chaos.spec import ChaosSpec

__all__ = ["json_schema", "validate_spec"]


def json_schema() -> dict[str, Any]:
    """Return the JSON Schema for a single chaos entry.

    Returns:
        A JSON-serializable mapping derived from :class:`ChaosSpec`.
    """
    return ChaosSpec.model_json_schema()


def validate_spec(data: Any) -> ChaosSpec:
    """Validate a raw mapping against :class:`ChaosSpec`.

    Args:
        data: A mapping authored in a task file (one chaos entry).

    Returns:
        The constructed :class:`ChaosSpec` instance.

    Raises:
        pydantic.ValidationError: If ``data`` does not match the schema.
    """
    try:
        return ChaosSpec.model_validate(data)
    except ValidationError:
        raise
