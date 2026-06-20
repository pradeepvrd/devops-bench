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

"""Registry-driven schema for chaos specs (Phase 4).

A chaos entry has a :class:`~devops_bench.chaos.base.Trigger`, a
:class:`~devops_bench.chaos.base.Fault` (action), and an optional ``verify``
key that *references* a verification entry by name. The reference is **opaque
to chaos**: chaos never constructs or imports a :mod:`verification` node — the
harness resolves the key against the verification registry (CONVENTIONS §4).

The Phase-A hand-maintained ``Annotated[Union, Field(discriminator="type")]``
has been swapped for registry-driven parsers (CONVENTIONS.md §4 "Phase-A → Phase-4
swap"): :class:`ChaosSpec`'s ``model_validator(mode="before")`` reads
``data["action"]["type"]`` / ``data["trigger"]["type"]``, looks the class up in
:data:`FAULTS` / :data:`TRIGGERS`, and validates the payload against it.
Adding a new fault or trigger now needs **no central edit** to this module —
register the class and parse-then-go.

To keep the importing this module light, the concrete fault/trigger modules
are imported lazily inside the parser (the first parse pulls them); the spec
module itself depends only on ``core`` and ``pydantic``. This is what lets
``import devops_bench.chaos`` stay clear of the agent + models chain.
"""

from __future__ import annotations

from typing import Any

from pydantic import AliasChoices, BaseModel, ConfigDict, Field, ValidationError, model_validator
from pydantic_core import PydanticCustomError

from devops_bench.chaos.registry import FAULTS, TRIGGERS
from devops_bench.core import NotRegisteredError

__all__ = [
    "ChaosSpec",
    "parse_fault",
    "parse_trigger",
]


def parse_fault(data: Any) -> BaseModel:
    """Parse a fault (``action``) payload through :data:`FAULTS`.

    Args:
        data: A mapping carrying a ``type`` discriminator, or an already-parsed
            :class:`pydantic.BaseModel` (returned as-is when registered).

    Returns:
        The concrete fault selected by ``data["type"]``.

    Raises:
        pydantic.ValidationError: If ``data`` is not a mapping, omits ``type``,
            names an unregistered fault, or fails the target model's validation.
    """
    return _parse_through(data, FAULTS, axis="fault")


def parse_trigger(data: Any) -> BaseModel:
    """Parse a trigger payload through :data:`TRIGGERS`.

    Args:
        data: A mapping carrying a ``type`` discriminator, or an already-parsed
            :class:`pydantic.BaseModel` (returned as-is when registered).

    Returns:
        The concrete trigger selected by ``data["type"]``.

    Raises:
        pydantic.ValidationError: If ``data`` is not a mapping, omits ``type``,
            names an unregistered trigger, or fails the target model's validation.
    """
    return _parse_through(data, TRIGGERS, axis="trigger")


def _parse_through(data: Any, registry: Any, *, axis: str) -> BaseModel:
    """Resolve ``data["type"]`` against ``registry`` and validate the payload.

    Args:
        data: Authored payload or an already-parsed model instance.
        registry: The :data:`FAULTS` or :data:`TRIGGERS` registry to consult.
        axis: ``"fault"`` or ``"trigger"`` — used to label error messages.

    Returns:
        The validated concrete model instance.

    Raises:
        pydantic.ValidationError: If ``data`` cannot be resolved or validated.
    """
    # Trigger lazy registration on first parse. Importing these modules has the
    # decorator side effect that populates FAULTS / TRIGGERS; the imports stay
    # local so simply importing :mod:`devops_bench.chaos.spec` does not.
    _ensure_concretes_loaded()

    if isinstance(data, BaseModel):
        if type(data) in set(registry.values()):
            return data
        raise _validation_error(
            f"chaos_spec_unregistered_{axis}_model",
            (
                f"chaos {axis} node {type(data).__name__!r} is not a "
                f"registered {axis}"
            ),
            input_value=data,
        )
    if not isinstance(data, dict):
        raise _validation_error(
            f"chaos_spec_{axis}_not_mapping",
            f"chaos {axis} node must be a mapping, got {type(data).__name__}",
            input_value=data,
        )

    type_key = data.get("type")
    if not isinstance(type_key, str):
        raise _validation_error(
            f"chaos_spec_{axis}_missing_type",
            f"chaos {axis} node is missing required ``type`` discriminator",
            input_value=data,
        )

    try:
        model_cls = registry.get(type_key)
    except NotRegisteredError as exc:
        raise _validation_error(
            f"chaos_spec_unknown_{axis}_type",
            (
                f"unknown chaos {axis} type {type_key!r}; "
                f"registered: {sorted(registry.keys())}"
            ),
            input_value=data,
        ) from exc

    return model_cls.model_validate(data)


def _ensure_concretes_loaded() -> None:
    """Import the bundled fault/trigger modules so the registries populate.

    The Phase-4 parser is registry-driven, so adding a fault no longer requires
    an edit to this file — but the bundled concretes still need to be loaded
    for the harness's default-parse path to find them. The imports stay
    function-local so importing :mod:`devops_bench.chaos.spec` itself stays
    clear of the agent / models chain (the lazy-import in
    :meth:`GenerateLoadFault.inject` is what holds that line — these imports
    only pull the fault *class*, not the agent).
    """
    # The `_ALREADY_LOADED` flag avoids re-running the imports on every parse.
    global _CONCRETES_LOADED
    if _CONCRETES_LOADED:
        return
    # noqa: F401 — imported for the @FAULTS.register / @TRIGGERS.register side effects.
    from devops_bench.chaos.faults import generate_load  # noqa: F401
    from devops_bench.chaos.triggers import time_delay  # noqa: F401

    _CONCRETES_LOADED = True


_CONCRETES_LOADED = False


def _validation_error(
    code: str, message: str, *, input_value: Any
) -> ValidationError:
    """Build a :class:`ValidationError` around a single :class:`PydanticCustomError`.

    The registry's :class:`NotRegisteredError` carries useful context, but the
    rest of the codebase catches :class:`pydantic.ValidationError` for spec
    parsing; wrapping keeps that single error surface.
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
    trigger: Any
    action: Any
    verify: str | None = Field(
        default=None,
        validation_alias=AliasChoices("verify", "verification"),
    )

    @model_validator(mode="before")
    @classmethod
    def _parse_nodes(cls, data: Any) -> Any:
        """Route ``trigger`` / ``action`` payloads through the registry parsers."""
        if not isinstance(data, dict):
            return data
        out = dict(data)
        if "trigger" in out:
            out["trigger"] = parse_trigger(out["trigger"])
        if "action" in out:
            out["action"] = parse_fault(out["action"])
        return out
