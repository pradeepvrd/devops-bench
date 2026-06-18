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

"""Recursive dispatcher that evaluates a verification specification."""

from __future__ import annotations

import time

from devops_bench.verification.base import VerificationResult
from devops_bench.verification.spec import VerificationSpec

__all__ = ["VerifierAgent"]


class VerifierAgent:
    """Evaluate single or compound verification specs against cluster state."""

    def wait_for_condition(
        self,
        spec: VerificationSpec | dict | list,
        timeout_sec: int = 120,
    ) -> VerificationResult:
        """Wait for a spec to hold, recursing into compound specs.

        A list spec evaluates its members in order; a dict spec evaluates its
        named members. In both cases the per-member timeout is the time
        remaining out of ``timeout_sec``, and the overall result succeeds only
        when every member succeeds. A single spec delegates to its verifier.

        Args:
            spec: A :class:`VerificationSpec`, or a raw dict/list it can parse.
            timeout_sec: Total budget shared across the (possibly nested) checks.

        Returns:
            The aggregated verification result.
        """
        if not isinstance(spec, VerificationSpec):
            spec = VerificationSpec(spec)

        root = spec.root
        start_time = time.time()

        if isinstance(root, list):
            results: list[VerificationResult] = []
            overall_success = True
            overall_reason: list[str] = []
            for i, sub_spec in enumerate(root):
                remaining_timeout = self._remaining(start_time, timeout_sec)
                if remaining_timeout <= 0:
                    # Budget exhausted: do not run the remaining members; record
                    # them as timed out instead of granting each a fresh second.
                    overall_success = False
                    sub_result = self._timed_out_result(start_time)
                    results.append(sub_result)
                    overall_reason.append(f"spec[{i}] failed: {sub_result.reason}")
                    continue
                sub_result = self.wait_for_condition(sub_spec, timeout_sec=remaining_timeout)
                results.append(sub_result)
                if not sub_result.success:
                    overall_success = False
                    overall_reason.append(f"spec[{i}] failed: {sub_result.reason}")
                else:
                    overall_reason.append(f"spec[{i}] succeeded")
            return VerificationResult(
                success=overall_success,
                elapsed_time=time.time() - start_time,
                reason="; ".join(overall_reason),
                details=results,
            )

        if isinstance(root, dict):
            named_results: dict[str, VerificationResult] = {}
            overall_success = True
            overall_reason = []
            for name, sub_spec in root.items():
                remaining_timeout = self._remaining(start_time, timeout_sec)
                if remaining_timeout <= 0:
                    # Budget exhausted: record the unrun member as timed out.
                    overall_success = False
                    sub_result = self._timed_out_result(start_time)
                    named_results[name] = sub_result
                    overall_reason.append(f"{name} failed: {sub_result.reason}")
                    continue
                sub_result = self.wait_for_condition(sub_spec, timeout_sec=remaining_timeout)
                named_results[name] = sub_result
                if not sub_result.success:
                    overall_success = False
                    overall_reason.append(f"{name} failed: {sub_result.reason}")
                else:
                    overall_reason.append(f"{name} succeeded")
            return VerificationResult(
                success=overall_success,
                elapsed_time=time.time() - start_time,
                reason="; ".join(overall_reason),
                details=named_results,
            )

        # root is a single verifier (PodHealthyVerifier / ScalingCompleteVerifier).
        return root.verify(timeout_sec)

    @staticmethod
    def _remaining(start_time: float, timeout_sec: int) -> int:
        """Return the seconds left in the budget.

        May be zero or negative once the budget is exhausted; callers use that to
        short-circuit rather than running another member with a borrowed second.
        """
        elapsed = time.time() - start_time
        return timeout_sec - int(elapsed)

    @staticmethod
    def _timed_out_result(start_time: float) -> VerificationResult:
        """Build a failed result for a member skipped due to an exhausted budget."""
        return VerificationResult(
            success=False,
            elapsed_time=time.time() - start_time,
            reason="timed out before evaluation (verification budget exhausted)",
        )
