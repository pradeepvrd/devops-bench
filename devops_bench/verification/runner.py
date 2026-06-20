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

"""Deadline-based dispatcher that evaluates a verification specification.

The whole verification races a single monotonic deadline computed once at the
top of :meth:`VerifierAgent.wait_for_condition`. Sequence nodes consume the
deadline serially and fail fast (later children are recorded as skipped);
parallel nodes hand each child the full remaining deadline and AND the results.
Leaves consume the deadline directly via ``leaf.verify(remaining)``.

Invariant: if a per-node ``timeout`` override is added later, it may only
*tighten* the inherited deadline (``effective = min(inherited, now + override)``).
Never extend it. That override is intentionally **not** added now; this is the
documented extension point.
"""

from __future__ import annotations

import time
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import wait as futures_wait
from typing import Any

from devops_bench.verification.base import VerificationResult
from devops_bench.verification.spec import (
    ParallelSpec,
    SequenceSpec,
    VerificationSpec,
)

__all__ = ["VerifierAgent"]

_MAX_PARALLEL_WORKERS = 8


def _node_name(node: Any) -> str | None:
    """Echo the optional ``name`` label from a spec node, if any."""
    return getattr(node, "name", None)


def _timed_out(node: Any, reason: str) -> VerificationResult:
    """Build a failed result for a node that ran into the deadline."""
    return VerificationResult(
        success=False,
        elapsed_time=0.0,
        reason=reason,
        name=_node_name(node),
    )


def _skipped(node: Any, reason: str) -> VerificationResult:
    """Build a failed result for a node skipped by sequence fail-fast / deadline."""
    return VerificationResult(
        success=False,
        elapsed_time=0.0,
        reason=reason,
        name=_node_name(node),
    )


class VerifierAgent:
    """Evaluate single or compound verification specs against cluster state.

    All evaluations share a single monotonic deadline established by
    :meth:`wait_for_condition`. Compound nodes propagate the deadline without
    rebudgeting; leaves consume it directly via their ``verify`` method.
    """

    def wait_for_condition(
        self,
        spec: VerificationSpec | Any,
        timeout_sec: float = 120,
    ) -> VerificationResult:
        """Wait for a spec to hold within ``timeout_sec``.

        Args:
            spec: A :class:`VerificationSpec`, an already-parsed node, or a raw
                mapping the spec validator can parse.
            timeout_sec: Total wall-clock budget shared across the (possibly
                nested) checks. A single monotonic deadline is computed from
                this once at the top.

        Returns:
            The aggregated verification result.
        """
        if isinstance(spec, VerificationSpec):
            node: Any = spec.root
        elif isinstance(spec, SequenceSpec | ParallelSpec):
            node = spec
        elif hasattr(spec, "verify"):
            # Already a concrete leaf verifier.
            node = spec
        else:
            node = VerificationSpec(spec).root

        deadline = time.monotonic() + timeout_sec
        return self._run(node, deadline)

    def _run(self, node: Any, deadline: float) -> VerificationResult:
        """Dispatch a node against the shared deadline."""
        if isinstance(node, SequenceSpec):
            return self._run_sequence(node, deadline)
        if isinstance(node, ParallelSpec):
            return self._run_parallel(node, deadline)
        return self._run_leaf(node, deadline)

    def _run_leaf(self, node: Any, deadline: float) -> VerificationResult:
        """Run a leaf verifier with whatever budget remains on the deadline."""
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return _timed_out(node, "deadline exhausted before evaluation")
        return node.verify(remaining)

    def _run_sequence(self, node: SequenceSpec, deadline: float) -> VerificationResult:
        """Run children in order; stop and skip the rest on the first failure."""
        start = time.monotonic()
        children: list[VerificationResult] = []
        reasons: list[str] = []
        ok = True
        for i, child in enumerate(node.checks):
            if time.monotonic() >= deadline:
                children.append(_skipped(child, "deadline exhausted"))
                reasons.append(f"[{i}] skipped")
                ok = False
                continue
            res = self._run(child, deadline)
            children.append(res)
            if not res.success:
                ok = False
                reasons.append(f"[{i}] failed: {res.reason}")
                for j, rest in enumerate(node.checks[i + 1 :], start=i + 1):
                    children.append(_skipped(rest, "earlier step failed"))
                    reasons.append(f"[{j}] skipped")
                break  # fail-fast
            reasons.append(f"[{i}] succeeded")
        return VerificationResult(
            success=ok,
            elapsed_time=time.monotonic() - start,
            reason="; ".join(reasons),
            name=node.name,
            children=children,
        )

    def _run_parallel(self, node: ParallelSpec, deadline: float) -> VerificationResult:
        """Run children concurrently; each sees the full remaining deadline.

        A parallel child still blocked in ``kubectl wait`` / ``poll_until`` when
        the deadline hits is bounded by the ``remaining`` value handed to its
        ``verify`` call, so worker threads do not linger long past the deadline.
        """
        start = time.monotonic()
        if not node.checks:
            return VerificationResult(
                success=True,
                elapsed_time=time.monotonic() - start,
                reason="no checks",
                name=node.name,
                children=[],
            )
        results: list[VerificationResult | None] = [None] * len(node.checks)
        workers = min(_MAX_PARALLEL_WORKERS, len(node.checks))
        with ThreadPoolExecutor(max_workers=workers) as ex:
            futs = {
                ex.submit(self._run, child, deadline): i
                for i, child in enumerate(node.checks)
            }
            done, _ = futures_wait(futs, timeout=max(0.0, deadline - time.monotonic()))
            for f, i in futs.items():
                if f in done:
                    results[i] = f.result()
                else:
                    results[i] = _timed_out(node.checks[i], "deadline reached")
        materialized: list[VerificationResult] = [
            r if r is not None else _timed_out(node.checks[i], "deadline reached")
            for i, r in enumerate(results)
        ]
        ok = all(r.success for r in materialized)
        reasons = [
            f"[{i}] {'ok' if r.success else 'fail'}" for i, r in enumerate(materialized)
        ]
        return VerificationResult(
            success=ok,
            elapsed_time=time.monotonic() - start,
            reason="; ".join(reasons),
            name=node.name,
            children=materialized,
        )
