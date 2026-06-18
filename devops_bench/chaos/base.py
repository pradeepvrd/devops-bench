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

"""Chaos fault/trigger interfaces and their selection registries."""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any

from devops_bench.core import Registry

__all__ = ["Fault", "Trigger", "FAULTS", "TRIGGERS"]

FAULTS: Registry[type[Fault]] = Registry("faults")
TRIGGERS: Registry[type[Trigger]] = Registry("triggers")


class Fault(ABC):
    """Abstract base for a platform-agnostic disruption or failure state.

    A fault describes *what* to disrupt independent of the target platform.
    Concrete faults live in sibling modules under ``chaos.faults`` and
    self-register under a canonical key via ``@FAULTS.register(...)``.

    Attributes:
        id: Stable identifier for this fault instance.
        name: Human-readable name.
        target_subsystem: Subsystem the fault targets (e.g. ``"network"``).
    """

    id: str
    name: str
    target_subsystem: str

    @abstractmethod
    def get_agnostic_spec(self) -> dict[str, Any]:
        """Return the standardized, platform-agnostic parameters of the fault.

        Returns:
            A JSON-serializable dict describing the disruption.
        """

    @abstractmethod
    def inject(self, spec: dict[str, Any], context: dict[str, Any] | None = None) -> dict[str, Any]:
        """Inject the fault into the target platform.

        Args:
            spec: Platform-agnostic fault spec (the chaos task definition).
            context: Optional execution context (signaling events, runtime
                params) forwarded by the caller.

        Returns:
            A JSON-serializable report describing the outcome.
        """


class Trigger(ABC):
    """Abstract base for the condition that decides when a fault should fire.

    A trigger evaluates platform-agnostic state (provided by a verifier or
    monitoring source) and lives outside any chaos infrastructure. Concrete
    triggers self-register under a canonical key via ``@TRIGGERS.register(...)``.

    Attributes:
        id: Stable identifier for this trigger instance.
        name: Human-readable name.
        trigger_type: Discriminator describing the trigger heuristic.
    """

    id: str
    name: str
    trigger_type: str

    def initialize(self, context: dict[str, Any]) -> None:
        """Initialize trigger state (e.g. baselines or internal timers).

        Args:
            context: Platform-agnostic context used to seed the trigger.
        """
        return None

    @abstractmethod
    def is_triggered(self, current_platform_state: dict[str, Any]) -> bool:
        """Evaluate state to decide whether the fault should be injected.

        Args:
            current_platform_state: Platform-agnostic state snapshot.

        Returns:
            True when the fault should fire.
        """
