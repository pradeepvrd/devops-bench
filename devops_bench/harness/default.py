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

"""Default harness: the decomposed end-to-end evaluation pipeline."""

from __future__ import annotations

import datetime
import importlib
import json
import os
import threading
from typing import Any

from devops_bench.agents import AGENTS, AgentHarness
from devops_bench.core import (
    NotRegisteredError,
    RunContext,
    get_bool,
    get_env,
    get_logger,
)
from devops_bench.deployers.factory import get_deployer
from devops_bench.harness import scenario as scenario_module
from devops_bench.harness.artifacts import collect_generated_files, snapshot_dir
from devops_bench.harness.base import Harness
from devops_bench.harness.scenario import ScenarioManager

__all__ = ["DefaultHarness"]

_log = get_logger("harness.default")

# Agent type -> module to import so the concrete harness self-registers in
# AGENTS. The legacy ``cli`` / ``binary`` types map onto the gemini CLI harness;
# canonical keys (``gemini`` / ``openclaw`` / ``api``) resolve directly.
_AGENT_MODULES = {
    "cli": "devops_bench.agents.cli.gemini",
    "binary": "devops_bench.agents.cli.gemini",
    "gemini": "devops_bench.agents.cli.gemini",
    "openclaw": "devops_bench.agents.cli.openclaw",
    "api": "devops_bench.agents.api.loop",
}
_AGENT_KEYS = {"cli": "gemini", "binary": "gemini"}

# Default target deployment + namespace used both for placeholder substitution
# in the agent prompt and as the chaos port-forward target, so the operator
# agent and the chaos injector address the same workload when env is unset.
_DEFAULT_TARGET_DEPLOYMENT = "hypercomputer-d1-frontend"
_DEFAULT_NAMESPACE = "default"

# How long to wait for the chaos agent to establish its load spike before
# starting the operator agent.
_CHAOS_ACTIVE_WAIT_SEC = 45

# Budget for draining the scenario thread. Kept above the verification budget
# (defined in scenario.py) so a slow-but-completing verification is not cut off,
# which would otherwise yield partial reports and race teardown.
_SCENARIO_JOIN_SEC = scenario_module.VERIFICATION_TIMEOUT_SEC + 60


class DefaultHarness(Harness):
    """Standard harness wiring every component into one pipeline.

    Each task flows through provisioning, optional background chaos, agent
    execution, artifact collection, teardown, and batch scoring. The agent under
    test is resolved from the :data:`~devops_bench.agents.AGENTS` registry by
    type, keeping execution model- and provider-agnostic.

    Args:
        project_id: Default GCP project ID for provisioning and placeholders.
        cluster_name: Default cluster name for provisioning and placeholders.
        judge_model: A ``DeepEvalBaseLLM`` judge used for scoring; when ``None``
            one is built from ``JUDGE_PROVIDER`` / ``JUDGE_MODEL`` on first use.
        results_root: Directory under which timestamped run dirs are created.
    """

    def __init__(
        self,
        project_id: str,
        cluster_name: str,
        judge_model: Any | None = None,
        results_root: str = "results",
    ) -> None:
        self.project_id = project_id
        self.cluster_name = cluster_name
        self._judge_model = judge_model
        self.results_root = results_root
        self.agent_type = (get_env("BENCH_AGENT_TYPE", "cli") or "cli").lower()
        self.agent_target = get_env("AGENT_TARGET", "./my-agent")

    # -- agent resolution (model/provider-agnostic) -----------------------

    def resolve_agent(self, agent_type: str) -> AgentHarness:
        """Resolve and instantiate the agent under test from the registry.

        The concrete harness module is imported so it self-registers, then the
        class is looked up in :data:`~devops_bench.agents.AGENTS` and constructed.
        No branching on provider or direct import of a concrete agent occurs.

        Args:
            agent_type: Configured agent type (e.g. ``cli`` / ``api`` / ``gemini``).

        Returns:
            An instantiated :class:`~devops_bench.agents.AgentHarness`.

        Raises:
            ValueError: If ``agent_type`` maps to no known agent module.
            NotRegisteredError: If the imported module did not register an agent
                under the resolved key.
        """
        module_name = _AGENT_MODULES.get(agent_type)
        if module_name is None:
            raise ValueError(f"unknown agent type: {agent_type!r}")
        importlib.import_module(module_name)
        key = _AGENT_KEYS.get(agent_type, agent_type)
        agent_cls = AGENTS.get(key)
        # AGENTS.get raises on a true miss, but guard against a module that
        # imported yet failed to register (a None/falsy entry) so the caller sees
        # a clear error instead of an opaque ``TypeError`` from ``None()``.
        if agent_cls is None:
            raise NotRegisteredError(AGENTS.name, key, AGENTS.keys())
        return agent_cls()

    # -- placeholder substitution -----------------------------------------

    def replace_placeholders(self, text: str, cluster_name: str) -> str:
        """Substitute infrastructure placeholders in a prompt or expectation.

        ``TARGET_DEPLOYMENT_NAME`` and ``NAMESPACE`` form the integration contract
        supplied by the provisioning layer after cluster bring-up.

        Args:
            text: Text containing ``{{...}}`` placeholders.
            cluster_name: Active cluster name to substitute.

        Returns:
            The text with all known placeholders replaced.
        """
        app_location = get_env("APP_LOCATION", "") or ""
        target_deployment = (
            get_env("TARGET_DEPLOYMENT_NAME", _DEFAULT_TARGET_DEPLOYMENT)
            or _DEFAULT_TARGET_DEPLOYMENT
        )
        namespace = get_env("NAMESPACE", _DEFAULT_NAMESPACE) or _DEFAULT_NAMESPACE
        return (
            text.replace("{{PROJECT_ID}}", self.project_id)
            .replace("{{GCP_PROJECT_ID}}", self.project_id)
            .replace("{{CLUSTER_NAME}}", cluster_name)
            .replace("{{GKE_CLUSTER_NAME}}", cluster_name)
            .replace("{{APP_LOCATION}}", app_location)
            .replace("{{TARGET_DEPLOYMENT_NAME}}", target_deployment)
            .replace("{{NAMESPACE}}", namespace)
        )

    # -- scenario (background chaos) --------------------------------------

    def start_scenario(
        self, chaos_spec: Any, verification_spec: Any, cluster_name: str
    ) -> tuple[ScenarioManager, threading.Thread] | None:
        """Start a background chaos+verification scenario on a daemon thread.

        Placeholders in the specs are resolved, the first chaos spec is selected,
        and :meth:`ScenarioManager.run_chaos_and_verification` is run on a daemon
        thread so the operator agent can proceed concurrently.

        Args:
            chaos_spec: Raw chaos spec (dict/list/str) or None.
            verification_spec: Raw decoupled verification specs or None.
            cluster_name: Active cluster name for placeholder substitution.

        Returns:
            A ``(scenario_manager, thread)`` pair, or None when no chaos spec is
            present or it could not be started.
        """
        if not chaos_spec:
            return None

        target_deployment = (
            get_env("TARGET_DEPLOYMENT_NAME", _DEFAULT_TARGET_DEPLOYMENT)
            or _DEFAULT_TARGET_DEPLOYMENT
        )
        namespace = get_env("NAMESPACE", _DEFAULT_NAMESPACE) or _DEFAULT_NAMESPACE

        try:
            spec_list = self._process_spec(chaos_spec, cluster_name)
            verification_spec_list: list[dict[str, Any]] = []
            if verification_spec:
                verification_spec_list = self._process_spec(verification_spec, cluster_name)

            if not spec_list:
                return None

            spec = spec_list[0]
            scenario_manager = ScenarioManager(target_deployment, namespace)
            thread = threading.Thread(
                target=scenario_manager.run_chaos_and_verification,
                args=(spec, verification_spec_list),
            )
            thread.daemon = True
            thread.start()
            return scenario_manager, thread
        except Exception as exc:
            _log.warning("failed to start ScenarioManager: %s", exc)
            return None

    def _process_spec(self, spec: Any, cluster_name: str) -> list[dict[str, Any]]:
        """Resolve placeholders in a spec and parse it into a list."""
        raw = json.dumps(spec) if isinstance(spec, (dict, list)) else str(spec)
        return json.loads(self.replace_placeholders(raw, cluster_name))

    # -- agent execution --------------------------------------------------

    def execute_agent(self, prompt: str, context: RunContext) -> dict[str, Any]:
        """Run the configured agent against ``prompt`` through the registry.

        Args:
            prompt: The (placeholder-resolved) task prompt.
            context: The per-task run context forwarded to the agent.

        Returns:
            The agent's standardized result dict.
        """
        agent = self.resolve_agent(self.agent_type)
        agent_context = {"cluster": context.cluster} if context.cluster else {}
        return agent.run(prompt, agent_context)

    # -- pipeline ---------------------------------------------------------

    def run(self, eval_data: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Run the full pipeline over ``eval_data`` and return scored results.

        Args:
            eval_data: Loaded task specs.

        Returns:
            The detailed per-task result dicts, scored in place.
        """
        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        run_dir = os.path.join(self.results_root, f"run_{timestamp}")
        os.makedirs(run_dir, exist_ok=True)

        detailed_results: list[dict[str, Any]] = [
            self._run_one(item, run_dir) for item in eval_data
        ]

        # Persist raw execution outputs before the (slower) scoring pass.
        self._write_results(run_dir, detailed_results)
        _log.info("execution complete; results saved to %s/results.json", run_dir)

        self._score(detailed_results)
        self._write_results(run_dir, detailed_results)
        _log.info(
            "post-processing evaluation complete; updated results saved to %s/results.json",
            run_dir,
        )
        return detailed_results

    def _run_one(self, item: dict[str, Any], run_dir: str) -> dict[str, Any]:
        """Provision, run the agent, collect artifacts, tear down for one task.

        Args:
            item: The task spec being evaluated.
            run_dir: The run output directory for generated artifacts.

        Returns:
            The detailed result dict. On any failure a ``status: "failed"``
            record (with ``error`` and ``score: 0``) is returned instead of being
            dropped, so failures stay visible to downstream parsers.
        """
        infra_config = item.get("infrastructure", {})
        deployer = get_deployer(infra_config, self.project_id, self.cluster_name)
        scenario_manager: ScenarioManager | None = None
        result: dict[str, Any] | None = None

        try:
            _log.info("provisioning infrastructure for: %s", item["name"])
            deployer.up()
            cluster_info = deployer.get_cluster_info()
            active_cluster_name = cluster_info.name or self.cluster_name
            context = self.make_context(item, cluster=cluster_info)

            prompt = self.replace_placeholders(item["input"], active_cluster_name)

            scenario = self.start_scenario(
                item.get("chaos_spec"),
                item.get("verification_spec"),
                active_cluster_name,
            )
            if scenario is not None:
                scenario_manager, scenario_thread = scenario
                _log.info("waiting for chaos agent to establish the cluster load spike...")
                scenario_manager.chaos_active_event.wait(timeout=_CHAOS_ACTIVE_WAIT_SEC)
                _log.info("cluster load spike active; proceeding with operator agent...")
            else:
                scenario_thread = None

            _log.info("executing agent for prompt: %s", prompt)
            before_files = snapshot_dir(".")
            agent_res = self.execute_agent(prompt, context)
            collect_generated_files(before_files, run_dir)

            expected_output = self.replace_placeholders(
                item.get("expected_output", ""), active_cluster_name
            )

            chaos_report, perf_report = self._drain_scenario(
                scenario_manager, scenario_thread, agent_res
            )

            result = {
                "input": prompt,
                "output": agent_res.get("output", ""),
                "latency": agent_res.get("latency", 0.0),
                "tokens": agent_res.get("tokens", {}),
                "tools": agent_res.get("tools", {}),
                "trajectory": agent_res.get("trajectory", []),
                "skills": agent_res.get("skills", []),
                "name": item["name"],
                "status": "success",
                "expected_output": expected_output,
                "expected_output_raw": item.get("expected_output", ""),
                "retrieval_context": item.get("retrieval_context", []),
                "chaos_spec": item.get("chaos_spec"),
                "verification_spec": item.get("verification_spec"),
                "chaos_report": chaos_report,
                "perf_report": perf_report,
                "documentation": item.get("documentation", []),
            }
            _log.info("agent response for %s:\n%s", item["name"], result["output"])
        except Exception as exc:
            _log.error("critical error during task %s: %s", item.get("name"), exc)
            result = self._failed_record(item, exc)
        finally:
            # Release the scenario's thread + port-forward + fortio even when the
            # task errored before _drain_scenario joined it, so nothing leaks into
            # the next task.
            if scenario_manager is not None:
                scenario_manager.stop()
            self._teardown(deployer, infra_config, item.get("name", ""))

        return result

    @staticmethod
    def _failed_record(item: dict[str, Any], exc: Exception) -> dict[str, Any]:
        """Build a minimal failed-task record so the failure stays visible.

        Args:
            item: The task spec that failed.
            exc: The exception that aborted the task.

        Returns:
            A result dict marked ``status: "failed"`` with ``score: 0`` and the
            error message, carrying through the task's identifying fields.
        """
        return {
            "input": item.get("input", ""),
            "output": "",
            "latency": 0.0,
            "tokens": {},
            "tools": {},
            "trajectory": [],
            "skills": [],
            "name": item.get("name", ""),
            "status": "failed",
            "error": str(exc),
            "score": 0,
            "expected_output": item.get("expected_output", ""),
            "expected_output_raw": item.get("expected_output", ""),
            "retrieval_context": item.get("retrieval_context", []),
            "chaos_spec": item.get("chaos_spec"),
            "verification_spec": item.get("verification_spec"),
            "chaos_report": {},
            "perf_report": {},
            "documentation": item.get("documentation", []),
        }

    def _drain_scenario(
        self,
        scenario_manager: ScenarioManager | None,
        scenario_thread: threading.Thread | None,
        agent_res: dict[str, Any],
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        """Join the scenario thread and return its chaos and perf reports.

        Args:
            scenario_manager: The running scenario, or None.
            scenario_thread: The scenario's daemon thread, or None.
            agent_res: The agent result, used as a fallback source of reports.

        Returns:
            A ``(chaos_report, perf_report)`` pair.
        """
        if scenario_manager is None or scenario_thread is None:
            return agent_res.get("chaos_report", {}), agent_res.get("perf_report", {})
        _log.info("waiting for background metrics collection to complete...")
        scenario_thread.join(timeout=_SCENARIO_JOIN_SEC)
        return scenario_manager.get_reports()

    def _teardown(
        self, deployer: Any, infra_config: dict[str, Any], name: str
    ) -> None:
        """Tear down infrastructure unless disabled by config or env.

        Args:
            deployer: The deployer to tear down.
            infra_config: Task infrastructure config (``teardown`` flag).
            name: Task name, for logging.
        """
        if get_bool("BENCH_NO_TEARDOWN"):
            return
        if not infra_config.get("teardown", True):
            return
        _log.info("tearing down infrastructure for: %s", name)
        try:
            deployer.down()
        except Exception as exc:
            _log.error("teardown failed (potential resource leak): %s", exc)

    def _score(self, detailed_results: list[dict[str, Any]]) -> None:
        """Score the batch in place via the metrics pipeline.

        Args:
            detailed_results: Execution results to score; ``scores`` is written
                into each in place. Records marked ``status: "failed"`` are
                skipped, since there is no agent output to judge.
        """
        scorable = [r for r in detailed_results if r.get("status") != "failed"]
        if not scorable:
            return
        # Lazy import keeps deepeval/provider SDKs out of harness import.
        from devops_bench.metrics import evaluate_metrics_batch, get_judge_model

        judge_model = self._judge_model or get_judge_model()
        evaluate_metrics_batch(scorable, judge_model)

    @staticmethod
    def _write_results(run_dir: str, detailed_results: list[dict[str, Any]]) -> None:
        """Write the detailed results to ``<run_dir>/results.json``."""
        with open(os.path.join(run_dir, "results.json"), "w") as f:
            json.dump(detailed_results, f, indent=2)
