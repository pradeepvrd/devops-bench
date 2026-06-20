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

"""Registry-driven schema for verification specs.

A spec is one of the type-tagged leaves (e.g. ``pod_healthy``,
``scaling_complete``) or a compound node (``sequence``, ``parallel``). The
``name`` field is metadata for result labeling only; recursion is explicit via
the compound nodes' ``checks`` list. Bare lists or dicts as spec nodes are
rejected — authoring is explicit-``type``-only.

The Phase-A hand-maintained ``Annotated[Union, Field(discriminator="type")]``
has been swapped for a registry-driven parser (CONVENTIONS.md §4, Phase 4):
:class:`VerificationSpec`'s ``model_validator(mode="before")`` reads
``data["type"]``, looks the class up in :data:`VERIFIERS`, and validates the
dict against it. The runner's ``isinstance`` dispatch on :class:`SequenceSpec`
and :class:`ParallelSpec` is intentionally unchanged — only parsing is
registry-driven.
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, RootModel, ValidationError, model_validator
from pydantic_core import PydanticCustomError

# Importing the leaf verifier modules triggers their ``@VERIFIERS.register``
# decorators so the registry is populated before any parse runs. These imports
# stay light — leaves import only ``core`` and ``k8s``.
from devops_bench.core import NotRegisteredError
from devops_bench.verification import verifiers as _verifiers  # noqa: F401
from devops_bench.verification.registry import VERIFIERS

__all__ = [
    "ParallelSpec",
    "SequenceSpec",
    "VerificationNode",
    "VerificationSpec",
    "parse_node",
]

# ``VerificationNode`` is the conceptual union of every registered verifier; we
# alias to ``Any`` to keep type-checkers happy without rebuilding a static
# discriminated union (which is exactly what this swap eliminates).
VerificationNode = Any



def _parse_compound_children(cls: type, data: Any) -> Any:
    """Recurse into ``checks`` so each child is parsed through the registry.

    Shared between :class:`SequenceSpec` and :class:`ParallelSpec` so the two
    compound nodes carry one ``model_validator(mode="before")`` implementation
    instead of byte-identical copies.

    Args:
        cls: The compound model class (provided by the pydantic validator).
        data: The raw payload pydantic is about to validate.

    Returns:
        The payload unchanged when no ``checks`` key is present; otherwise a
        shallow copy with each child already parsed through :func:`parse_node`.
    """
    if isinstance(data, dict) and "checks" in data:
        data = {**data, "checks": [parse_node(c) for c in data["checks"]]}
    return data


@VERIFIERS.register("sequence")
class SequenceSpec(BaseModel):
    """Ordered, fail-fast group: members run in sequence; stop at first failure.

    Attributes:
        type: Discriminator literal, always ``"sequence"``.
        name: Optional label echoed onto the result; metadata, never structural.
        checks: Ordered child nodes; each is itself a parsed verifier node.
    """

    type: Literal["sequence"]
    name: str | None = None
    checks: list[Any]

    _parse_children = model_validator(mode="before")(_parse_compound_children)


@VERIFIERS.register("parallel")
class ParallelSpec(BaseModel):
    """Independent group: members run concurrently; all must pass.

    Attributes:
        type: Discriminator literal, always ``"parallel"``.
        name: Optional label echoed onto the result; metadata, never structural.
        checks: Sibling child nodes; each is itself a parsed verifier node.
    """

    type: Literal["parallel"]
    name: str | None = None
    checks: list[Any]

    _parse_children = model_validator(mode="before")(_parse_compound_children)


def parse_node(data: Any) -> BaseModel:
    """Parse one verifier-spec node dict through the registry.

    Args:
        data: A node mapping carrying a ``type`` discriminator, or an already
            parsed :class:`pydantic.BaseModel` (returned as-is).

    Returns:
        The concrete verifier or compound spec selected by ``data["type"]``.

    Raises:
        pydantic.ValidationError: If ``data`` is not a mapping, omits ``type``,
            names an unregistered type, or fails the target model's validation.
    """
    if isinstance(data, BaseModel):
        if type(data) in set(VERIFIERS.values()):
            return data
        raise _validation_error(
            "verification_spec_unregistered_model",
            (
                f"verification spec node {type(data).__name__!r} is not a "
                "registered verifier"
            ),
            input_value=data,
        )
    if not isinstance(data, dict):
        # Surface as a ValidationError so callers see pydantic's familiar error
        # surface even when an entry is the wrong shape (e.g. a bare list).
        raise _validation_error(
            "verification_spec_not_mapping",
            f"verification spec node must be a mapping, got {type(data).__name__}",
            input_value=data,
        )

    type_key = data.get("type")
    if not isinstance(type_key, str):
        raise _validation_error(
            "verification_spec_missing_type",
            "verification spec node is missing required ``type`` discriminator",
            input_value=data,
        )

    try:
        model_cls = VERIFIERS.get(type_key)
    except NotRegisteredError as exc:
        raise _validation_error(
            "verification_spec_unknown_type",
            (
                f"unknown verifier type {type_key!r}; "
                f"registered: {sorted(VERIFIERS.keys())}"
            ),
            input_value=data,
        ) from exc

    return model_cls.model_validate(data)


def _validation_error(
    code: str, message: str, *, input_value: Any
) -> ValidationError:
    """Build a ``ValidationError`` around a single ``PydanticCustomError``.

    The registry's :class:`NotRegisteredError` carries useful context, but the
    rest of the codebase catches ``pydantic.ValidationError`` for spec parsing;
    wrapping keeps that single error surface.
    """
    custom = PydanticCustomError(code, message)
    return ValidationError.from_exception_data(
        title=code,
        line_errors=[
            {
                "type": custom,
                "loc": (),
                "input": input_value,
            }
        ],
    )


class VerificationSpec(RootModel[Any]):
    """Entry-point wrapper; ``VerificationSpec(data).root`` yields a concrete node.

    The ``root`` is dispatched through :func:`parse_node` so a new verifier =
    register-then-go, with no central edit to a static union.

    Example:
        >>> spec = VerificationSpec({"type": "pod_healthy", "selector": "app=web"})
        >>> spec.root.type
        'pod_healthy'
    """

    root: Any

    @model_validator(mode="before")
    @classmethod
    def _parse(cls, data: Any) -> Any:
        """Route the raw root payload through the registry parser."""
        # ``RootModel`` validates the payload at the ``root`` field, so this
        # ``before`` validator sees the user-supplied data verbatim.
        return parse_node(data)
