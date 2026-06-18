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

"""Background scenario orchestration: chaos injection plus verification."""

from __future__ import annotations

import json
import subprocess
import threading
import time
from typing import Any

from devops_bench.chaos import ChaosAgent
from devops_bench.core import get_logger
from devops_bench.verification import VerifierAgent

__all__ = ["ScenarioManager"]

_log = get_logger("harness.scenario")

# Local port the cluster workload is exposed on for chaos load generation.
_LOCAL_PORT = 8080
_LOCAL_SERVICE_URL = f"http://localhost:{_LOCAL_PORT}"

# Seconds to let ``kubectl port-forward`` establish the tunnel before load.
_PORT_FORWARD_SETTLE_SEC = 3

# Verification budget shared across the (possibly nested) checks.
_VERIFICATION_TIMEOUT_SEC = 120

# The only chaos action type the manager drives today (planned load spike).
_SUPPORTED_ACTION_TYPE = "generate_load"


class ScenarioManager:
    """Orchestrate a background chaos disruption and its verification.

    The manager runs on a daemon thread alongside the agent under test: it opens
    a ``kubectl port-forward`` to the target deployment, drives a
    :class:`~devops_bench.chaos.ChaosAgent` to inject a planned load spike against
    ``http://localhost:8080``, then waits for a verification condition to hold and
    aggregates the chaos and performance reports.

    Args:
        target_deployment: Deployment to port-forward and disrupt.
        namespace: Namespace the deployment lives in.

    Attributes:
        chaos_active_event: Set by the chaos agent once the load spike begins, so
            the harness can synchronize the operator agent's start.
    """

    def __init__(self, target_deployment: str, namespace: str) -> None:
        self.target_deployment = target_deployment
        self.namespace = namespace
        self.chaos_active_event = threading.Event()
        self.chaos_agent = ChaosAgent(chaos_active_event=self.chaos_active_event)
        self.verifier_agent = VerifierAgent()
        self.result_holder: dict[str, dict[str, Any]] = {
            "chaos_report": {},
            "perf_report": {},
        }
        self.start_time: float | None = None
        self.pf_process: subprocess.Popen[bytes] | None = None

    def run_chaos_and_verification(
        self,
        spec: dict[str, Any],
        verification_specs: list[dict[str, Any]] | None = None,
    ) -> None:
        """Inject the planned fault, then gather verification metrics.

        Args:
            spec: A single chaos spec with ``trigger``, ``action``, and
                ``verification`` keys. ``verification`` may be an inline dict or a
                string naming an entry in ``verification_specs``.
            verification_specs: Decoupled named verification specs referenced by
                name from ``spec['verification']``.
        """
        self.start_time = time.time()
        trigger = spec.get("trigger", {})
        action = spec.get("action", {})
        verification_ref = spec.get("verification", {})

        verification: dict[str, Any] = {}
        if isinstance(verification_ref, str):
            if verification_specs:
                for v_spec in verification_specs:
                    if v_spec.get("name") == verification_ref:
                        verification = v_spec
                        break
        elif isinstance(verification_ref, dict):
            verification = verification_ref

        # Record initial chaos metadata before injection begins.
        self.result_holder["chaos_report"] = {
            "injected_fault": action.get("type", "generate_load"),
            "name": spec.get("name", "Planned Disruption"),
            "status": "initiated",
        }

        try:
            self._inject_chaos_with_delay(trigger, action)
            self.result_holder["chaos_report"]["status"] = "success"
        except Exception as exc:
            _log.error("error running scenario: %s", exc)
            self.result_holder["chaos_report"]["status"] = "failed"
            self.result_holder["chaos_report"]["error"] = str(exc)
            return

        if verification:
            _log.info("starting planned verification using VerifierAgent...")
            try:
                verification_result = self.verifier_agent.wait_for_condition(
                    verification, timeout_sec=_VERIFICATION_TIMEOUT_SEC
                )
                _log.info(
                    "verification completed: %s",
                    verification_result.model_dump_json(indent=2),
                )
                self.result_holder["chaos_report"]["verification"] = (
                    verification_result.model_dump()
                )

                # Derive the performance report from the verification outcome.
                elapsed_time = verification_result.elapsed_time
                success = verification_result.success
                self.result_holder["perf_report"] = {
                    "deployment_time_seconds": elapsed_time if success else None,
                    "uptime_percentage": 100.0 if success else 0.0,
                    "resource_utilization_efficiency": 1.0 if success else 0.0,
                }
            except Exception as exc:
                _log.error("verification failed with exception: %s", exc)
                self.result_holder["chaos_report"]["verification"] = {
                    "success": False,
                    "reason": f"Verification exception: {exc}",
                }

    def _inject_chaos_with_delay(
        self, trigger: dict[str, Any], action: dict[str, Any]
    ) -> None:
        """Honor the trigger delay, port-forward, then run the chaos agent.

        Args:
            trigger: Trigger spec; ``delay_seconds`` defers injection.
            action: Chaos action spec; its load target is rewritten to the local
                port-forwarded URL before injection.
        """
        delay = trigger.get("delay_seconds", 0)
        if delay > 0:
            _log.info("waiting for trigger delay of %ss...", delay)
            time.sleep(delay)

        # 1. Establish a long-lived kubectl port-forward to the local port. This
        # is a genuinely long-running process held open for the duration of load
        # generation, so it uses subprocess.Popen directly rather than the
        # one-shot core.subprocess.run helper (which blocks until completion).
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
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        # Give the tunnel a moment to establish.
        time.sleep(_PORT_FORWARD_SETTLE_SEC)

        # 2. Redirect chaos load generation to the local port-forwarded URL.
        local_action = action.copy()
        local_action["target"] = dict(local_action.get("target", {}))
        local_action["target"]["service_url"] = _LOCAL_SERVICE_URL

        _log.info("triggering chaos action: generate_load on %s", _LOCAL_SERVICE_URL)
        try:
            self._inject_fault(local_action)
        except Exception as exc:
            _log.error("error during chaos injection: %s", exc)
            raise
        finally:
            # 3. Always terminate the port-forward once load generation is done.
            _log.info("terminating GKE port-forward...")
            if self.pf_process is not None:
                self.pf_process.terminate()
                self.pf_process.wait()
                _log.info("port-forward terminated.")

    def _inject_fault(self, action: dict[str, Any]) -> None:
        """Drive the chaos agent to execute the planned load action.

        Args:
            action: Chaos action spec already rewritten to target the local URL.

        Raises:
            ValueError: If ``action['type']`` is not the supported load type.
        """
        action_type = action.get("type", _SUPPORTED_ACTION_TYPE)
        if action_type != _SUPPORTED_ACTION_TYPE:
            raise ValueError(f"unsupported chaos action type {action_type!r}")
        goal = (
            "Your goal is to execute the following GKE planned chaos engineering "
            "disruption action:\n"
            f"```json\n{json.dumps(action, indent=2)}\n```\n\n"
            "Use the 'fortio' tool via your run_command tool to inject traffic "
            f"against {_LOCAL_SERVICE_URL}. Execute exactly one load spike, then "
            "report the results and exit."
        )
        self.chaos_agent.run(goal)

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
