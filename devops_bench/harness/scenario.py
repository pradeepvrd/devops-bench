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

"""Background chaos + verification on a daemon thread, with port-forward.

The harness drives chaos and verification through their typed seams: it calls
``trigger.wait(ctx)`` and then ``action.inject(ctx, event)`` to get a
:class:`~devops_bench.chaos.ChaosResult`, and resolves
:attr:`ChaosSpec.verify` (an opaque string key) against a name-keyed
verification mapping supplied by the caller. **Chaos never imports
verification** — the mapping lookup is the wiring the harness owns
(CONVENTIONS.md §1, §4.2).

The :class:`~devops_bench.verification.VerifierAgent` evaluates the resolved
node and returns a typed :class:`~devops_bench.verification.VerificationResult`.
``model_dump()`` shapes both reports into plain dicts; the on-disk schema is
the legacy mixed shape (Decision D3) the :class:`ResultReporter` writes.
"""

from __future__ import annotations

import subprocess
import threading
import time
from typing import Any

from devops_bench.chaos import ChaosSpec
from devops_bench.core import get_logger
from devops_bench.core.context import RunContext
from devops_bench.verification import VerifierAgent

__all__ = ["ScenarioManager", "VERIFICATION_TIMEOUT_SEC"]

_log = get_logger("harness.scenario")

# Local port the cluster workload is exposed on for chaos load generation.
_LOCAL_PORT = 8080
_LOCAL_SERVICE_URL = f"http://localhost:{_LOCAL_PORT}"

# Seconds to let ``kubectl port-forward`` establish the tunnel before load.
_PORT_FORWARD_SETTLE_SEC = 3

# Verification budget shared across the (possibly nested) checks.
VERIFICATION_TIMEOUT_SEC = 120


def _rewrite_action_target_url(spec: ChaosSpec) -> ChaosSpec:
    """Return a clone of ``spec`` whose action targets the local port-forward.

    The action's typed ``target.service_url`` is rewritten in place on the
    clone (the original spec is left untouched). When the action carries no
    ``target`` attribute the spec is returned unchanged, so triggers / actions
    added later that do not address a service URL are no-ops here.
    """
    clone = spec.model_copy(deep=True)
    action = clone.action
    target = getattr(action, "target", None)
    if target is not None and hasattr(target, "service_url"):
        target.service_url = _LOCAL_SERVICE_URL
    return clone


class ScenarioManager:
    """Orchestrate a background chaos disruption and its verification.

    The manager runs on a daemon thread alongside the agent under test: it
    opens a ``kubectl port-forward`` to the target deployment, drives the
    typed :class:`~devops_bench.chaos.base.Fault` (via ``action.inject``) to
    inject the planned disruption against the local URL, then resolves the
    spec's ``verify:`` key against the per-task verification mapping and runs
    :meth:`~devops_bench.verification.VerifierAgent.wait_for_condition` on
    the resolved node.

    Args:
        target_deployment: Deployment to port-forward and disrupt.
        namespace: Namespace the deployment lives in.
        verification_mapping: Name-keyed mapping of verification specs the
            chaos ``verify:`` reference is resolved against. The mapping carries
            already-validated :class:`VerificationSpec` instances (or any value
            ``VerifierAgent.wait_for_condition`` accepts); the manager never
            re-validates. Empty mapping disables verification lookups.
        skip_port_forward: When True, the manager runs the chaos seam without
            opening a ``kubectl port-forward``. The E2E smoke harness (against
            :class:`~devops_bench.deployers.NoOpDeployer`) flips this on so
            tests can exercise the wiring without a real cluster.

    Attributes:
        chaos_active_event: Set by the chaos fault once the disruption is
            observably active, so the harness can synchronize the operator
            agent's start.
    """

    def __init__(
        self,
        target_deployment: str,
        namespace: str,
        verification_mapping: dict[str, Any] | None = None,
        *,
        skip_port_forward: bool = False,
    ) -> None:
        self.target_deployment = target_deployment
        self.namespace = namespace
        self.verification_mapping: dict[str, Any] = dict(verification_mapping or {})
        self.skip_port_forward = skip_port_forward
        self.chaos_active_event = threading.Event()
        self.verifier_agent = VerifierAgent()
        self.result_holder: dict[str, dict[str, Any]] = {
            "chaos_report": {},
            "perf_report": {},
        }
        self.start_time: float | None = None
        self.pf_process: subprocess.Popen[bytes] | None = None
        self._aborted = threading.Event()

    def run_chaos_and_verification(
        self,
        spec: ChaosSpec,
        ctx: RunContext,
    ) -> None:
        """Inject the planned fault, then gather verification metrics.

        Args:
            spec: A typed :class:`ChaosSpec` carrying the trigger, action, and
                opaque ``verify:`` key to resolve.
            ctx: The per-task run context (forwarded to the trigger / fault).
        """
        self.start_time = time.time()

        # Record initial chaos metadata before injection begins, so a crash
        # mid-injection still produces a partial report rather than silence.
        self.result_holder["chaos_report"] = {
            "injected_fault": spec.action.type,
            "name": spec.name,
            "status": "initiated",
        }

        try:
            chaos_result = self._inject_chaos_with_delay(spec, ctx)
            self.result_holder["chaos_report"] = self._chaos_report_from_result(
                spec, chaos_result
            )
        except Exception as exc:  # noqa: BLE001 - surface failure into the report
            _log.error("error running scenario: %s", exc)
            self.result_holder["chaos_report"]["status"] = "failed"
            self.result_holder["chaos_report"]["error"] = str(exc)
            return

        if self._aborted.is_set():
            return

        verification_node = self._resolve_verification(spec.verify)
        if verification_node is None:
            # No verification scheduled (``verify`` was None) — leave the
            # chaos_report alone. An UNKNOWN key, on the other hand, has
            # already stamped ``chaos_report["verification"]`` with the
            # failure record so the operator sees the typo'd cross-reference
            # on the run record, not just in the log.
            return

        _log.info("starting planned verification using VerifierAgent...")
        try:
            verification_result = self.verifier_agent.wait_for_condition(
                verification_node, timeout_sec=VERIFICATION_TIMEOUT_SEC
            )
            _log.info(
                "verification completed: %s",
                verification_result.model_dump_json(indent=2),
            )
            self.result_holder["chaos_report"]["verification"] = (
                verification_result.model_dump()
            )
            self.result_holder["perf_report"] = self._perf_from_verification(
                verification_result
            )
        except Exception as exc:  # noqa: BLE001 - surface failure into the report
            _log.error("verification failed with exception: %s", exc)
            self.result_holder["chaos_report"]["verification"] = {
                "success": False,
                "reason": f"Verification exception: {exc}",
            }

    def _inject_chaos_with_delay(self, spec: ChaosSpec, ctx: RunContext):
        """Honor the trigger delay, port-forward, then drive ``action.inject``.

        Args:
            spec: Typed chaos spec.
            ctx: Run context handed to the trigger / fault.

        Returns:
            The :class:`~devops_bench.chaos.ChaosResult` returned by the fault.
        """
        # The trigger is a typed node; wait through its own ``wait(ctx)`` rather
        # than reading raw ``delay_seconds`` here — the harness only knows the
        # ``Trigger`` Protocol, not the concrete trigger's parameters.
        spec.trigger.wait(ctx)

        rewritten = _rewrite_action_target_url(spec)

        if self.skip_port_forward:
            # E2E smoke / tests against NoOpDeployer skip the port-forward; the
            # chaos seam still runs end-to-end against whatever target the
            # action carries.
            return rewritten.action.inject(ctx, self.chaos_active_event)

        self._open_port_forward()
        try:
            return rewritten.action.inject(ctx, self.chaos_active_event)
        finally:
            # Always terminate the port-forward once injection completes (or
            # raises), so the tunnel never outlives the scenario thread.
            _log.info("terminating GKE port-forward...")
            if self.pf_process is not None:
                self.pf_process.terminate()
                self.pf_process.wait()
                _log.info("port-forward terminated.")

    def _open_port_forward(self) -> None:
        """Establish ``kubectl port-forward`` and fail fast if it dies early.

        The port-forward is held open for the duration of load generation, so
        it uses :func:`subprocess.Popen` directly rather than the one-shot
        ``core.subprocess.run`` helper. ``stdout``/``stderr`` go to
        ``DEVNULL`` because nothing reads the pipes — ``PIPE`` would let
        ``kubectl`` block once its output buffer fills under sustained load.
        """
        _log.info(
            "establishing port-forward to deployment/%s on port %d...",
            self.target_deployment,
            _LOCAL_PORT,
        )
        pf_cmd = [
            "kubectl",
            "port-forward",
            f"deployment/{self.target_deployment}",
            f"{_LOCAL_PORT}:{_LOCAL_PORT}",
            "-n",
            self.namespace,
        ]
        self.pf_process = subprocess.Popen(
            pf_cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        time.sleep(_PORT_FORWARD_SETTLE_SEC)
        if self.pf_process.poll() is not None:
            # Reap the already-exited child before raising so it does not
            # linger as a zombie waiting for ``wait()``. ``terminate`` is a
            # no-op on a process that already exited; ``wait`` collects the
            # exit status.
            returncode = self.pf_process.returncode
            try:
                self.pf_process.wait(timeout=_PORT_FORWARD_SETTLE_SEC)
            except Exception as exc:  # noqa: BLE001 - never mask the raise reason
                _log.warning("error reaping early-exited port-forward: %s", exc)
            raise RuntimeError(
                f"kubectl port-forward exited early (code {returncode}) "
                f"for deployment/{self.target_deployment} in {self.namespace!r}"
            )

    @staticmethod
    def _chaos_report_from_result(spec: ChaosSpec, result: Any) -> dict[str, Any]:
        """Shape a typed ``ChaosResult`` into the legacy chaos-report dict.

        Args:
            spec: The originating spec (carries the human-readable ``name``).
            result: A :class:`~devops_bench.chaos.ChaosResult`.

        Returns:
            The ``chaos_report`` dict consumed by the result reporter; the
            legacy ``status`` field is derived from ``ChaosResult.success`` so
            the on-disk schema is unchanged.
        """
        dumped = result.model_dump()
        # Carry both the legacy human-readable name and the typed result fields
        # so downstream consumers see a superset (Decision D3: preserve shape;
        # the typed fields are additive — no existing key is dropped).
        report: dict[str, Any] = {
            "injected_fault": result.injected_fault,
            "name": spec.name,
            "status": "success" if result.success else "failed",
            "output": dumped.get("output", ""),
            "elapsed_time": dumped.get("elapsed_time", 0.0),
        }
        if dumped.get("error") is not None:
            report["error"] = dumped["error"]
        return report

    @staticmethod
    def _perf_from_verification(result: Any) -> dict[str, Any]:
        """Derive the legacy ``perf_report`` shape from a verification result.

        Mirrors the legacy mapping: deployment time only flows through on
        success, and the placeholder uptime / utilization fields collapse to
        the same 100/0 binary the legacy code emitted. Kept identical so the
        ``results.json`` schema (Decision D3) is unchanged.
        """
        success = bool(result.success)
        elapsed = float(result.elapsed_time)
        return {
            "deployment_time_seconds": elapsed if success else None,
            "uptime_percentage": 100.0 if success else 0.0,
            "resource_utilization_efficiency": 1.0 if success else 0.0,
        }

    def _resolve_verification(self, verify_ref: str | None) -> Any | None:
        """Resolve the chaos spec's opaque ``verify`` key against the mapping.

        Args:
            verify_ref: The string key carried on :attr:`ChaosSpec.verify`, or
                ``None`` when the spec opts out of verification.

        Returns:
            The mapped verification node (already validated) when the key is
            present and known; ``None`` when the spec opts out **or** the
            key is unknown. The unknown-key case is *not* silent — a
            verification-failure entry is written into ``chaos_report``
            naming the missing key + the available keys, so a typo'd
            cross-reference shows up on the run record (not just in the
            log).
        """
        if not verify_ref:
            return None
        node = self.verification_mapping.get(verify_ref)
        if node is None:
            known = sorted(self.verification_mapping.keys())
            reason = (
                f"chaos verify reference {verify_ref!r} not found in "
                f"verification mapping; known keys: {known}"
            )
            _log.warning(reason)
            # Surface the unresolved reference on the chaos_report so the
            # operator sees the typo'd cross-reference in results.json, not
            # just in the log. The shape mirrors the typed
            # VerificationResult dump (success/reason/name) so downstream
            # consumers don't need a special-case parse path.
            self.result_holder["chaos_report"]["verification"] = {
                "success": False,
                "reason": reason,
                "name": verify_ref,
                "unresolved_reference": verify_ref,
                "known_references": known,
            }
            return None
        return node

    def get_reports(self) -> tuple[dict[str, Any], dict[str, Any]]:
        """Return the aggregated chaos and performance reports.

        Returns:
            A ``(chaos_report, perf_report)`` pair derived from the most recent
            scenario run; each is an empty dict before the run produces it.
        """
        return (
            self.result_holder.get("chaos_report", {}),
            self.result_holder.get("perf_report", {}),
        )

    def stop(self) -> None:
        """Abort the scenario and release its external resources.

        Sets an abort flag so a pending verification is skipped and terminates
        the ``kubectl port-forward`` process if it is still running. Safe to
        call more than once and from a different thread than the scenario's; it
        never raises, so it can run from a ``finally`` block during cleanup.
        """
        self._aborted.set()
        process = self.pf_process
        if process is not None and process.poll() is None:
            _log.info("stopping scenario: terminating GKE port-forward...")
            try:
                process.terminate()
                process.wait(timeout=_PORT_FORWARD_SETTLE_SEC)
            except Exception as exc:  # noqa: BLE001 - never raise during cleanup
                _log.warning("error terminating port-forward during stop: %s", exc)
