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

"""Result model and abstract base for verification checks."""

from __future__ import annotations

from abc import ABC, abstractmethod

from pydantic import BaseModel

__all__ = ["VerificationResult", "BaseVerifier"]


class VerificationResult(BaseModel):
    """Structured, recursive outcome of a verification check.

    Attributes:
        success: True when every condition the check covers was met.
        elapsed_time: Wall-clock seconds spent evaluating the check.
        reason: Human-readable summary of the outcome or failure.
        details: Supporting data. For compound specs this holds the child
            results keyed by name (dict spec) or in order (list spec); for
            single checks it carries raw kubectl output or diagnostics.
    """

    success: bool
    elapsed_time: float
    reason: str
    details: dict[str, VerificationResult] | list[VerificationResult] | dict | None = None


class BaseVerifier(BaseModel, ABC):
    """Abstract base for a single verification check.

    Concrete verifiers carry a ``type`` literal so they can participate in the
    discriminated :class:`~devops_bench.verification.spec.VerificationSpec`
    union, and implement :meth:`verify`.
    """

    @abstractmethod
    def verify(self, timeout_sec: int) -> VerificationResult:
        """Run the check and report the outcome.

        Args:
            timeout_sec: Maximum seconds the check may spend before giving up.

        Returns:
            The structured verification result.
        """
        raise NotImplementedError
