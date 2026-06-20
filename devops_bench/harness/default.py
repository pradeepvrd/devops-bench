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

"""Default harness: the decomposed end-to-end evaluation pipeline.

The orchestrator is **pure wiring** — it consumes the typed seams every Layer-2
component exposes and never re-implements behavior. The single registry
lookup pattern lets adding a new agent / fault / verifier / metric stay a
zero-edit drop-in (CONVENTIONS.md §2):

* **Agents** are resolved via :data:`devops_bench.agents.AGENTS`. The harness
  imports the four builtin agent modules once at call time so their
  ``@AGENTS.register`` decorators run; resolution is a pure ``AGENTS.get(key)``
  with no parallel path / alias tables.
* **Chaos** is driven through ``trigger.wait(ctx)`` and
  ``action.inject(ctx, event)`` against a typed
  :class:`~devops_bench.chaos.ChaosSpec`. The ``verify:`` reference is resolved
  against a name-keyed verification mapping the harness builds from the task
  spec — chaos never imports verification.
* **Verification** is dispatched by :class:`~devops_bench.verification.VerifierAgent`
  on the resolved typed node, producing a
  :class:`~devops_bench.verification.VerificationResult`.
* **Metrics** are scored by the registry-driven
  :func:`~devops_bench.metrics.evaluate_metrics_batch`, with the harness-owned
  ``use_mcp`` boolean threaded into :class:`~devops_bench.metrics.MetricContext`.

The harness is the **single** place that reads ``BENCH_USE_MCP``
(CONVENTIONS.md §7); the resolved boolean flows into both the
:class:`~devops_bench.agents.config.AgentConfig` it builds for the agent and
the metrics scoring call, so the agent and the judge cannot disagree on
whether tools were enabled.
"""

from __future__ import annotations

import importlib
import json
import os
import threading
from pathlib import Path
from typing import Any

from devops_bench.agents import AGENTS, AgentConfig, AgentResult
from devops_bench.agents.capabilities import (
    AgentCapabilities,
    AgentRules,
    McpBinding,
    SkillBinding,
)
from devops_bench.chaos import ChaosSpec
from devops_bench.core import (
    NotRegisteredError,
    RunContext,
    get_bool,
    get_env,
    get_logger,
)
from devops_bench.deployers.factory import get_deployer
from devops_bench.harness.artifacts import collect_generated_files, snapshot_dir
from devops_bench.harness.base import Harness
from devops_bench.harness.reporter import ResultReporter
from devops_bench.harness.scenario import VERIFICATION_TIMEOUT_SEC, ScenarioManager
from devops_bench.tasks import Task
from devops_bench.verification import VerificationSpec

__all__ = ["DefaultHarness"]

_log = get_logger("harness.default")

# Builtin agent modules to import at call time so their ``@AGENTS.register``
# decorators run — the harness never names module paths anywhere else
# (CONVENTIONS.md §2: registry-only resolution). A consumer / external
# package may add agents by registering with the same registry, with no edit
# here.
_BUILTIN_AGENT_MODULES: tuple[str, ...] = (
    "devops_bench.agents.cli.gemini",
    "devops_bench.agents.cli.openclaw",
    "devops_bench.agents.api.agent",
)

# Canonical alias map for legacy agent-type strings. Resolution still goes
# through ``AGENTS.get`` — these are pure key normalizations, kept in one
# place so adding / removing aliases is a one-line change. A future migration
# of the catalog to canonical keys is a single-edit cleanup.
_AGENT_TYPE_ALIASES: dict[str, str] = {
    "cli": "gemini",
    "binary": "gemini",
}

# Default target deployment + namespace used both for placeholder
# substitution in the agent prompt and as the chaos port-forward target, so the
# operator agent and the chaos injector address the same workload when env is
# unset.
_DEFAULT_TARGET_DEPLOYMENT = "hypercomputer-d1-frontend"
_DEFAULT_NAMESPACE = "default"

# How long to wait for the chaos agent to establish its load spike before
# starting the operator agent.
_CHAOS_ACTIVE_WAIT_SEC = 45

# Budget for draining the scenario thread. Kept above the verification budget
# so a slow-but-completing verification is not cut off, which would otherwise
# yield partial reports and race teardown.
_SCENARIO_JOIN_SEC = VERIFICATION_TIMEOUT_SEC + 60


def _ensure_builtin_agents_registered() -> None:
    """Import the builtin agent modules so their registrations fire.

    The registry is the only source of truth — this function exists so the
    harness can resolve canonical keys at call time without naming any module
    path in ``AGENTS.get``. Re-imports are no-ops thanks to ``sys.modules``.
    """
    for module in _BUILTIN_AGENT_MODULES:
        try:
            importlib.import_module(module)
        except Exception as exc:  # noqa: BLE001 - one missing optional dep must not abort
            # An agent module may pull an optional SDK (e.g. ``anthropic``) that
            # is absent on the host. Log and continue — only the agent whose key
            # the user actually selects needs to be importable, and ``AGENTS.get``
            # will raise a clear ``NotRegisteredError`` if it is missing.
            _log.debug("optional agent module %s not importable: %s", module, exc)


class DefaultHarness(Harness):
    """Standard harness wiring every component into one pipeline.

    Each task flows through provisioning, optional background chaos, agent
    execution, artifact collection, teardown, and batch scoring. Every layer
    is consumed through its typed contract: ``Task`` in, ``AgentResult`` from
    the agent, ``ChaosResult`` / ``VerificationResult`` from the scenario,
    ``MetricScore`` from each metric. The harness routes those typed values
    through ``to_dict()`` / ``to_entry()`` / ``model_dump()`` so the on-disk
    ``results.json`` schema (Decision D3) stays byte-stable.

    Args:
        project_id: Default GCP project ID for provisioning and placeholders.
        cluster_name: Default cluster name for provisioning and placeholders.
        judge_model: A ``DeepEvalBaseLLM`` judge used for scoring; when ``None``
            one is built from ``JUDGE_PROVIDER`` / ``JUDGE_MODEL`` on first use.
        results_root: Directory under which timestamped run dirs are created.
        reporter: Optional explicit result reporter (the engine depends on the
            sink, not on ``json.dump``; ``harness-refactor-handoff.md`` §8). A
            default :class:`ResultReporter` rooted at ``results_root`` is built
            when omitted.
    """

    def __init__(
        self,
        project_id: str,
        cluster_name: str,
        judge_model: Any | None = None,
        results_root: str = "results",
        *,
        reporter: ResultReporter | None = None,
    ) -> None:
        self.project_id = project_id
        self.cluster_name = cluster_name
        self._judge_model = judge_model
        self.results_root = results_root
        self.agent_type = (get_env("BENCH_AGENT_TYPE", "cli") or "cli").lower()
        # Single, harness-owned read of ``BENCH_USE_MCP`` (CONVENTIONS.md §7).
        # The resolved boolean is threaded into both the AgentConfig
        # capabilities and the metrics scoring call; nothing downstream
        # re-reads the env.
        self.use_mcp: bool = get_bool("BENCH_USE_MCP", True)
        self.reporter = reporter or ResultReporter(results_root)

    # -- agent resolution (model/provider-agnostic) -----------------------

    def resolve_agent(self, agent_type: str) -> Any:
        """Resolve and instantiate the agent under test from the registry.

        The builtin agent modules are imported once so their
        ``@AGENTS.register`` decorators run, the legacy alias is normalized to
        the canonical key, and the class is fetched from
        :data:`~devops_bench.agents.AGENTS`. The harness names no module
        paths past :data:`_BUILTIN_AGENT_MODULES` (CONVENTIONS.md §2) — an
        externally-registered agent resolves the same way with **no harness
        edit**.

        Args:
            agent_type: Configured agent type (e.g. ``cli`` / ``api`` /
                ``gemini`` / ``openclaw``).

        Returns:
            An instantiated agent harness. The instance is built with the
            harness-resolved :class:`AgentConfig` so capabilities (MCP / skills /
            rules) reflect the orchestrator's catalog × run-arm decision.

        Raises:
            NotRegisteredError: If no agent is registered under the resolved
                canonical key.
        """
        _ensure_builtin_agents_registered()
        key = _AGENT_TYPE_ALIASES.get(agent_type, agent_type)
        agent_cls = AGENTS.get(key)
        if agent_cls is None:
            raise NotRegisteredError(AGENTS.name, key, AGENTS.keys())
        return agent_cls(self.build_agent_config())

    # -- agent config + capabilities (explicit; no env detour) ------------

    def build_agent_config(self) -> AgentConfig:
        """Build the :class:`AgentConfig` for the next agent run.

        Capabilities are constructed **explicitly** from the harness-owned
        ``use_mcp`` boolean (CONVENTIONS.md §7) and the ``AGENT_*`` env vars
        that describe the run arm (target binary, MCP server command, allowed
        tools, skill paths, operator brief). No deeper code re-reads
        ``BENCH_USE_MCP``: when MCP is gated off, the harness simply omits the
        MCP binding here, so the agent's tools-enabled gate returns ``False``
        and the metric context's ``use_mcp`` flag agrees with what the agent
        actually saw.

        Returns:
            A populated :class:`AgentConfig` with capabilities reflecting the
            harness's catalog × run-arm decision.
        """
        # Start from the env-derived shape so existing AGENT_* knobs continue
        # to flow through (model, provider, api_key, target, timeout, max
        # turns, extra_env) without re-implementing them here. Replace
        # capabilities with the orchestrator-owned aggregate so the agent
        # cannot see a granted MCP binding when ``use_mcp`` is False.
        base = AgentConfig.from_env()
        capabilities = self._gate_capabilities(base.capabilities, self.use_mcp)
        return AgentConfig(
            model=base.model,
            provider=base.provider,
            api_key=base.api_key,
            target=base.target,
            timeout_sec=base.timeout_sec,
            max_turns=base.max_turns,
            capabilities=capabilities,
            extra_env=base.extra_env,
        )

    @staticmethod
    def _gate_capabilities(
        env_caps: AgentCapabilities, use_mcp: bool
    ) -> AgentCapabilities:
        """Apply the harness's ``use_mcp`` gate to an env-derived capability set.

        Skills and rules are independent of MCP and pass through unchanged;
        only the MCP binding is dropped when ``use_mcp`` is False. The
        returned aggregate is always a fresh frozen dataclass so the caller
        does not mutate the input.

        Args:
            env_caps: Capabilities derived from the ``AGENT_*`` env layer.
            use_mcp: Whether the orchestrator granted MCP for this run.

        Returns:
            The gated :class:`AgentCapabilities` to attach to the next
            :class:`AgentConfig`.
        """
        if use_mcp:
            mcp_servers: tuple[McpBinding, ...] = env_caps.mcp_servers
        else:
            # MCP gated off: drop the binding so the agent's tools-enabled gate
            # is False and metrics' ``use_mcp`` agrees with what ran.
            mcp_servers = ()

        return AgentCapabilities(
            mcp_servers=mcp_servers,
            skills=env_caps.skills if env_caps.skills.paths else SkillBinding(),
            rules=env_caps.rules if env_caps.rules.text else AgentRules(),
        )

    # -- placeholder substitution -----------------------------------------

    def replace_placeholders(self, text: str, cluster_name: str) -> str:
        """Substitute infrastructure placeholders in a prompt or expectation.

        ``TARGET_DEPLOYMENT_NAME`` and ``NAMESPACE`` form the integration
        contract supplied by the provisioning layer after cluster bring-up.

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

    def _resolve_spec_placeholders(self, spec: Any, cluster_name: str) -> Any:
        """Walk an opaque spec, substituting placeholders in every string leaf.

        The post-Phase-B task files author chaos / verification as native YAML
        (Decision D2), so placeholder substitution can no longer route through
        a single ``str``-shaped value. This helper walks the nested
        list/dict structure once and rewrites only string leaves, leaving
        every other type untouched.

        Args:
            spec: An opaque chaos / verification spec value (mapping, list,
                scalar, or ``None``).
            cluster_name: Active cluster name passed through to
                :meth:`replace_placeholders`.

        Returns:
            A new structure with placeholders resolved. ``None`` round-trips
            unchanged so a missing spec stays missing.
        """
        if spec is None:
            return None
        if isinstance(spec, str):
            return self.replace_placeholders(spec, cluster_name)
        if isinstance(spec, list):
            return [self._resolve_spec_placeholders(item, cluster_name) for item in spec]
        if isinstance(spec, dict):
            return {
                key: self._resolve_spec_placeholders(value, cluster_name)
                for key, value in spec.items()
            }
        return spec

    # -- spec parsing (typed contracts at every seam) ---------------------

    def _parse_chaos_specs(self, raw: Any, cluster_name: str) -> list[ChaosSpec]:
        """Parse the raw task ``chaos_spec`` blob into typed :class:`ChaosSpec` list.

        Accepts both legacy JSON-in-YAML strings and native-YAML lists
        (Decision D2 keeps the field name but allows either value shape during
        the migration window). Each entry is placeholder-substituted, then
        validated through :class:`ChaosSpec`.
        """
        if not raw:
            return []
        resolved = self._resolve_spec_placeholders(raw, cluster_name)
        # Accept the legacy JSON-in-YAML string shape transparently: a
        # placeholder-substituted string round-trips through ``json.loads`` to
        # a list/dict the discriminated union can validate.
        if isinstance(resolved, str):
            try:
                resolved = json.loads(resolved)
            except json.JSONDecodeError as exc:
                _log.warning("could not parse chaos_spec JSON string: %s", exc)
                return []
        entries = resolved if isinstance(resolved, list) else [resolved]
        return [ChaosSpec.model_validate(entry) for entry in entries if entry]

    def _build_verification_mapping(
        self, raw: Any, cluster_name: str
    ) -> dict[str, Any]:
        """Build a name-keyed verification mapping the chaos seam consumes.

        Each entry is a mapping with a ``name`` field plus a typed
        verification node (either inline under a ``spec`` key, or as the
        entry itself when authored as a bare verifier). The harness validates
        every node through :class:`VerificationSpec` so the chaos seam hands a
        fully-typed value to :class:`~devops_bench.verification.VerifierAgent`.

        Args:
            raw: The task's ``verification_spec`` blob.
            cluster_name: Active cluster name for placeholder substitution.

        Returns:
            ``{name -> parsed VerificationSpec}``. An empty mapping is returned
            when the blob is missing or malformed; the caller's
            :meth:`ScenarioManager._resolve_verification` then warns on each
            unresolved reference rather than dropping verification silently.
        """
        if not raw:
            return {}
        resolved = self._resolve_spec_placeholders(raw, cluster_name)
        if isinstance(resolved, str):
            try:
                resolved = json.loads(resolved)
            except json.JSONDecodeError as exc:
                _log.warning("could not parse verification_spec JSON string: %s", exc)
                return {}
        entries = resolved if isinstance(resolved, list) else [resolved]

        mapping: dict[str, Any] = {}
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            name = entry.get("name")
            if not name:
                continue
            node = entry.get("spec") if "spec" in entry else entry
            try:
                mapping[name] = VerificationSpec(node)
            except Exception as exc:  # noqa: BLE001 - log + skip; never abort the run
                _log.warning(
                    "verification entry %r failed to validate; skipping: %s",
                    name,
                    exc,
                )
        return mapping

    # -- scenario (background chaos) --------------------------------------

    def start_scenario(
        self,
        chaos_specs: list[ChaosSpec],
        verification_mapping: dict[str, Any],
        ctx: RunContext,
        *,
        skip_port_forward: bool = False,
    ) -> tuple[ScenarioManager, threading.Thread] | None:
        """Start a background chaos+verification scenario on a daemon thread.

        Args:
            chaos_specs: Typed chaos entries (only the first is driven today,
                mirroring legacy behavior; multi-spec orchestration is a
                follow-up).
            verification_mapping: Name-keyed mapping of typed verification
                specs the chaos ``verify:`` key is resolved against.
            ctx: Per-task run context handed to triggers / faults.
            skip_port_forward: When True, do not open ``kubectl port-forward``;
                used by the E2E smoke harness when running against the
                :class:`~devops_bench.deployers.NoOpDeployer`.

        Returns:
            A ``(scenario_manager, thread)`` pair, or ``None`` when no chaos
            specs were provided.
        """
        if not chaos_specs:
            return None

        target_deployment = (
            get_env("TARGET_DEPLOYMENT_NAME", _DEFAULT_TARGET_DEPLOYMENT)
            or _DEFAULT_TARGET_DEPLOYMENT
        )
        namespace = get_env("NAMESPACE", _DEFAULT_NAMESPACE) or _DEFAULT_NAMESPACE

        spec = chaos_specs[0]
        scenario_manager = ScenarioManager(
            target_deployment,
            namespace,
            verification_mapping=verification_mapping,
            skip_port_forward=skip_port_forward,
        )
        thread = threading.Thread(
            target=scenario_manager.run_chaos_and_verification,
            args=(spec, ctx),
            daemon=True,
        )
        thread.start()
        return scenario_manager, thread

    # -- agent execution --------------------------------------------------

    def execute_agent(self, prompt: str, _ctx: RunContext) -> AgentResult:
        """Run the configured agent against ``prompt`` through the registry.

        Args:
            prompt: The (placeholder-resolved) task prompt.
            _ctx: The per-task run context. Reserved for future per-run hooks;
                today's agents consume only the resolved prompt and rely on
                their :class:`AgentConfig` for everything else (no env detour,
                no cluster handoff dict — CONVENTIONS.md §7).

        Returns:
            The typed :class:`AgentResult` the agent emitted.
        """
        agent = self.resolve_agent(self.agent_type)
        return agent.run(prompt)

    # -- pipeline ---------------------------------------------------------

    def run(self, tasks: list[Task]) -> list[dict[str, Any]]:
        """Run the full pipeline over ``tasks`` and return scored results.

        Args:
            tasks: Typed :class:`Task` objects produced by
                :func:`~devops_bench.tasks.load_tasks`.

        Returns:
            The detailed per-task result dicts, scored in place. The schema is
            the legacy ``results.json`` shape (Decision D3).
        """
        run_dir = self.reporter.new_run_dir()
        detailed_results: list[dict[str, Any]] = [
            self._run_one(task, run_dir) for task in tasks
        ]

        # Persist raw execution outputs before the (slower) scoring pass.
        self.reporter.write(run_dir, detailed_results)
        _log.info("execution complete; results saved to %s/results.json", run_dir)

        self._score(detailed_results)
        self.reporter.write(run_dir, detailed_results)
        _log.info(
            "post-processing evaluation complete; updated results saved to %s/results.json",
            run_dir,
        )
        return detailed_results

    def _run_one(self, task: Task, run_dir: Path) -> dict[str, Any]:
        """Provision, run the agent, collect artifacts, tear down for one task.

        Args:
            task: The typed task being evaluated.
            run_dir: The run output directory for generated artifacts.

        Returns:
            The detailed result dict. On any failure a ``status: "failed"``
            record (with ``error`` and ``score: 0``) is returned instead of
            being dropped, so failures stay visible to downstream parsers.
        """
        infra_config = task.infrastructure or {}
        deployer = get_deployer(infra_config, self.project_id, self.cluster_name)
        scenario_manager: ScenarioManager | None = None
        scenario_thread: threading.Thread | None = None
        result: dict[str, Any] | None = None
        workspace_path = Path(os.getcwd())

        try:
            _log.info("provisioning infrastructure for: %s", task.name)
            deployer.up()
            cluster_info = deployer.get_cluster_info()
            active_cluster_name = cluster_info.name or self.cluster_name
            context = self.make_context(
                task, cluster=cluster_info, workspace_path=workspace_path
            )

            prompt = self.replace_placeholders(task.prompt, active_cluster_name)

            chaos_specs = self._parse_chaos_specs(task.chaos_spec, active_cluster_name)
            verification_mapping = self._build_verification_mapping(
                task.verification_spec, active_cluster_name
            )

            scenario = self.start_scenario(chaos_specs, verification_mapping, context)
            if scenario is not None:
                scenario_manager, scenario_thread = scenario
                _log.info("waiting for chaos agent to establish the cluster load spike...")
                scenario_manager.chaos_active_event.wait(timeout=_CHAOS_ACTIVE_WAIT_SEC)
                _log.info("cluster load spike active; proceeding with operator agent...")

            _log.info("executing agent for prompt: %s", prompt)
            before_files = snapshot_dir(workspace_path)
            agent_res = self.execute_agent(prompt, context)
            collect_generated_files(before_files, run_dir, source_dir=workspace_path)

            expected_output = self.replace_placeholders(
                task.expected_output, active_cluster_name
            )

            chaos_report, perf_report = self._drain_scenario(
                scenario_manager, scenario_thread
            )

            result = self._build_success_record(
                task=task,
                prompt=prompt,
                expected_output=expected_output,
                agent_res=agent_res,
                chaos_report=chaos_report,
                perf_report=perf_report,
            )
            _log.info("agent response for %s:\n%s", task.name, result["output"])
        except Exception as exc:  # noqa: BLE001 - surface every task failure
            _log.error("critical error during task %s: %s", task.name, exc)
            result = self._failed_record(task, exc)
        finally:
            if scenario_manager is not None:
                scenario_manager.stop()
            self._teardown(deployer, infra_config, task.name)

        return result

    def _build_success_record(
        self,
        *,
        task: Task,
        prompt: str,
        expected_output: str,
        agent_res: AgentResult,
        chaos_report: dict[str, Any],
        perf_report: dict[str, Any],
    ) -> dict[str, Any]:
        """Shape a typed :class:`AgentResult` + reports into the legacy schema.

        The on-disk schema (Decision D3) is preserved by routing every typed
        value through ``to_dict()`` / ``model_dump()``. Capability metadata
        (``capabilities_granted``) is recorded on the result so metrics /
        downstream consumers can read what the agent was actually granted
        rather than re-reading ``BENCH_USE_MCP`` (CONVENTIONS.md §7).
        """
        dumped = agent_res.to_dict()
        record: dict[str, Any] = {
            "input": prompt,
            "output": dumped.get("output", ""),
            "latency": dumped.get("latency", 0.0),
            "tokens": dumped.get("tokens", {}),
            # Preserve the legacy ``tools`` key alongside the typed trajectory
            # so downstream consumers that only sample ``tools`` keep working;
            # the canonical trajectory is the source of truth.
            "tools": [entry.get("name") for entry in dumped.get("trajectory", []) if entry.get("name")],
            "trajectory": dumped.get("trajectory", []),
            "skills": list(self.use_mcp_skill_paths()),
            "name": task.name,
            "status": "success",
            "expected_output": expected_output,
            "expected_output_raw": task.expected_output,
            "retrieval_context": list(task.retrieval_context),
            "chaos_spec": task.chaos_spec,
            "verification_spec": task.verification_spec,
            "chaos_report": chaos_report,
            "perf_report": perf_report,
            "documentation": [doc.model_dump() for doc in task.documentation],
            "capabilities_granted": {
                "use_mcp": self.use_mcp,
                "skills": list(self.use_mcp_skill_paths()),
            },
        }
        if dumped.get("errors"):
            record["errors"] = dumped["errors"]
        return record

    def use_mcp_skill_paths(self) -> tuple[str, ...]:
        """Return the skill paths the harness granted (snapshot for the record).

        Pulled off the env-derived capability aggregate so the value on the
        run record matches what the agent actually saw, without requiring
        every consumer to re-read ``AGENT_SKILLS_PATHS``.
        """
        return AgentConfig.from_env().capabilities.skills.paths

    def _failed_record(self, task: Task, exc: Exception) -> dict[str, Any]:
        """Build a minimal failed-task record so the failure stays visible.

        Carries through the task's identifying fields and capability
        metadata so the on-disk schema is identical to a successful record
        (Decision D3) — only ``status``/``error``/``score`` differ.
        """
        return {
            "input": task.prompt,
            "output": "",
            "latency": 0.0,
            "tokens": {},
            "tools": [],
            "trajectory": [],
            "skills": list(self.use_mcp_skill_paths()),
            "name": task.name,
            "status": "failed",
            "error": str(exc),
            "score": 0,
            "expected_output": task.expected_output,
            "expected_output_raw": task.expected_output,
            "retrieval_context": list(task.retrieval_context),
            "chaos_spec": task.chaos_spec,
            "verification_spec": task.verification_spec,
            "chaos_report": {},
            "perf_report": {},
            "documentation": [doc.model_dump() for doc in task.documentation],
            "capabilities_granted": {
                "use_mcp": self.use_mcp,
                "skills": list(self.use_mcp_skill_paths()),
            },
        }

    def _drain_scenario(
        self,
        scenario_manager: ScenarioManager | None,
        scenario_thread: threading.Thread | None,
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        """Join the scenario thread and return its chaos and perf reports.

        Args:
            scenario_manager: The running scenario, or None.
            scenario_thread: The scenario's daemon thread, or None.

        Returns:
            A ``(chaos_report, perf_report)`` pair; both empty when no chaos
            was scheduled for the task.
        """
        if scenario_manager is None or scenario_thread is None:
            return {}, {}
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
        except Exception as exc:  # noqa: BLE001 - never raise during teardown
            _log.error("teardown failed (potential resource leak): %s", exc)

    def _score(self, detailed_results: list[dict[str, Any]]) -> None:
        """Score the batch in place via the metrics pipeline.

        The harness threads its single resolved ``use_mcp`` boolean into the
        metrics call (CONVENTIONS.md §7), so the agent and the judge cannot
        disagree on whether tools were enabled.

        Args:
            detailed_results: Execution results to score; ``scores`` is written
                into each in place. Records marked ``status: "failed"`` are
                skipped, since there is no agent output to judge.
        """
        scorable = [r for r in detailed_results if r.get("status") != "failed"]
        if not scorable:
            return
        # Lazy import keeps ``deepeval`` / provider SDKs out of harness import.
        from devops_bench.metrics import evaluate_metrics_batch, get_judge_model

        judge_model = self._judge_model or get_judge_model()
        evaluate_metrics_batch(scorable, judge_model, use_mcp=self.use_mcp)
