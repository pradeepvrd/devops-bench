# Handoff: Harness orchestrator alignment (PR #10 + follow-ups)

**Audience:** an implementing agent landing PR #10
(`feat(harness): evaluation orchestrator (Stage 3a)`, branch `feat/devops-bench-harness`,
fork `pradeepvrd/devops-bench`, base `integration/devops-bench-stage2-merged`) and the
harness-alignment follow-ups.
**Status:** PR #10 is a behavior-preserving port and is mergeable as-is; the §2 fixes are
ready to apply on the PR now; the §4–§9 alignment items are design-level recommendations whose
landing order is deferred to the cross-cutting sequencing plan (separate doc).

---

## 1. Context — why this work exists

PR #10 decomposes the legacy orchestrator (`pkg/manager/manager.py` + the `main()` loop of
`pkg/evaluator/evaluate.py`) into `devops_bench/harness/`:

- `base.py` — `Harness` ABC (`run(eval_data)` + `make_context(item, cluster)`) and the
  `RunContext` factory.
- `default.py` — `DefaultHarness`, the per-task phased pipeline (provision → query cluster →
  build context → placeholder substitution → start chaos → execute agent → collect artifacts →
  drain + teardown), followed by a batch scoring pass.
- `scenario.py` — `ScenarioManager`, background chaos + verification on a daemon thread, with
  kubectl port-forward and report aggregation.
- `artifacts.py` — `snapshot_dir` / `collect_generated_files` directory diffing.

**What the port gets right (keep it):**

- **Wiring topology is correct.** Agent execution is agent/model-agnostic via the `AGENTS`
  registry; scoring is delegated to `devops_bench.metrics` (not reimplemented); deployers come
  from `deployers.factory.get_deployer`; the `Harness` ABC is a minimal, clean extension seam.
- **Heavy deps are lazy.** `deepeval` / provider SDKs are imported inside `_score`, not at
  harness import — exactly the `__init__` hygiene the chaos/metrics handoffs demand.
- **Robustness improvements over legacy.** Failed tasks persist as `status:"failed"` +
  `score:0` (instead of being silently dropped); cleanup is exception-safe (`scenario.stop()`
  and teardown run in `finally`); the port-forward has a liveness poll.

**Why this doc exists.** PR #10 is intentionally the *before* state that the four sibling
refactor docs carve up — `chaos-refactor-handoff.md` §5.3 and
`verification-spec-redesign-handoff.md` §7c both name `harness/scenario.py` as their explicit
cleanup target. The harness is also the single node in the stack where every typed contract
collapses back into bare `dict`s, and it consumes the **pre-refactor** shapes of every
component it touches. That is coherent as sequencing *only if* these follow-ups are treated as
committed; left untracked, the port's dict-seams and inline logic ossify because everything
green-lights against them. This doc enumerates the alignment items and the seams to preserve.

> **Out of scope — already fixed.** The "blocker" findings in
> `docs/master_review_report.md` (kubectl port-forward pipe deadlock, mismatched
> chaos-vs-prompt deployment/namespace defaults, background-thread resource leak on early
> exception) are **already resolved in the current revision of PR #10**: stdout/stderr now go
> to `DEVNULL`; `_DEFAULT_TARGET_DEPLOYMENT` / `_DEFAULT_NAMESPACE` are shared module
> constants used by both `replace_placeholders` and `start_scenario`; `scenario_manager.stop()`
> runs in a `finally`. That review is stale on those points. Do **not** re-flag them.

---

## 2. PR #10 fix list (small, mergeable on the PR now)

File references are on branch `feat/devops-bench-harness`, all in `devops_bench/harness/`.

| # | Fix | File | Behavior impact |
|---|---|---|---|
| 1 | **Fold `_AGENT_MODULES` / `_AGENT_KEYS` into the `AGENTS` registry.** The harness keeps a private path map (`{"cli": "...gemini", "binary": "...gemini", …}`) plus a legacy-alias map and `importlib.import_module(...)` to trigger self-registration — a second registry layered on top of `AGENTS`. Resolve through `AGENTS` only; see §5. | `default.py` (`resolve_agent`, `_AGENT_MODULES`, `_AGENT_KEYS`) | None if alias keys are preserved in the registry; removes a parallel dispatch table. |
| 2 | **Read `BENCH_USE_MCP` once in the harness** and thread the resolved boolean down to scoring, instead of letting `metrics` re-read env independently. Closes the agent/metrics disagreement called out in `agents-refactor-handoff.md` §6 and `metrics-extensibility-handoff.md` §4.3. | `default.py` (`_score`) | None today (same default); prevents a latent agent-vs-judge mismatch. |
| 3 | **Use `RunContext.workspace_path` for snapshot/artifacts** rather than the hardcoded cwd `"."` in `snapshot_dir(".")` / `collect_generated_files(...)`. Makes the context load-bearing (see §6). | `default.py` (`_run_one`), `artifacts.py` | None when `workspace_path` defaults to cwd; enables non-cwd workspaces. |
| 4 | **Drop the legacy `input` key dependency** by reading the prompt through a single accessor so the eventual `Task` migration (§4) is a one-line change, not scattered `item["input"]` reads. | `default.py` (`_run_one`, `_failed_record`) | None. |

> Items 1–3 are behavior-neutral cleanups that make the §4–§9 alignment work strictly
> smaller. Item 4 is preparatory. None changes scoring or pipeline semantics.

---

## 3. Reviewer note (copy-paste into the PR)

> **What this PR is.** A behavior-preserving decomposition of the legacy orchestrator into
> `devops_bench/harness/`. Wiring is agent/model-agnostic (`AGENTS` registry), scoring is
> delegated to `devops_bench.metrics`, deployers come from the factory, and heavy deps
> (`deepeval`, provider SDKs) are lazy-imported in `_score`. Failed tasks are now recorded
> rather than dropped, and cleanup is exception-safe.
>
> **What this PR is *not*.** It is not the final architecture. By design it consumes the
> **pre-refactor** shapes of the components it touches and exchanges bare `dict`s at every
> seam (`run(eval_data: list[dict])` in; `result` / `chaos_report` / `perf_report` /
> `results.json` dicts out). The typed contracts these should become — `Task`, `AgentResult`,
> `ChaosResult`, `VerificationResult`, `MetricScore` — land in the sibling refactors
> (`docs/refactor/*-handoff.md`). Reviewers should expect the dict-seams here and not block on
> them; they are tracked as follow-ups (see `docs/refactor/harness-refactor-handoff.md`).
>
> **Already addressed (do not re-flag).** The `docs/master_review_report.md` blockers —
> port-forward pipe deadlock, mismatched chaos/prompt defaults, resource leak on early
> exception — are fixed in this revision (DEVNULL redirection; shared
> `_DEFAULT_TARGET_DEPLOYMENT` / `_DEFAULT_NAMESPACE`; `stop()` in `finally`).

---

## 4. The dict junction — typed contracts collapse here

### 4.1 Problem

The harness sits at the center of the pipeline, so it is exactly where the stack's typed
contracts *should converge*. Instead it is where they all dissolve into `dict[str, Any]`:

- **Input:** `run(eval_data: list[dict[str, Any]])` reads `item["input"]`, `item["name"]`,
  `item.get("chaos_spec")`, `item.get("verification_spec")`. But Stage 1's `Task` contract
  (PR #89) uses `prompt`, not `input` — the orchestrator does not consume the typed loader it
  is meant to sit on top of, and there is a live **`input` vs `prompt` key-name mismatch**.
- **Agent boundary:** `execute_agent` calls `agent.run(prompt, {"cluster": ...})` and reads a
  free-form result dict (`output`, `latency`, `tokens`, `tools`, `trajectory`, `skills`). The
  agents handoff defines a typed `AgentResult` for exactly this seam.
- **Chaos / verification boundary:** `ScenarioManager` produces `chaos_report` / `perf_report`
  dicts; the chaos and verification handoffs define `ChaosResult` and `VerificationResult`.
- **Output:** `results.json` is ad-hoc keys; the metrics handoff defines `MetricScore` /
  `Result`.

Every consumer downstream of the harness must therefore defensively `.get(...)` untyped dicts,
and a typo in a key name fails silently — the opposite of the "type-safe end to end, never
bare dicts" principle that recurs in all four sibling docs.

### 4.2 Recommendation

1. **Thread the `Task` contract.** Have `run()` accept `list[Task]` (or accept both and adapt
   `dict → Task` at the boundary during migration). This connects PR #89's typed loader and
   eliminates the `input`/`prompt` mismatch. The single-accessor change from §2 item 4 makes
   this a localized edit.
2. **Type the seams incrementally — even before the big component refactors.** Consume
   `AgentResult.to_dict()` (once the agents refactor exists) rather than a hand-shaped dict,
   and have the harness return a typed result object (or at minimum a `TypedDict`) so the later
   `ChaosResult` / `VerificationResult` / `MetricScore` retrofits drop in without re-plumbing
   the pipeline.
3. **Treat `results.json` shape as a contract.** When the seams become typed, route the
   on-disk schema through the typed objects' `to_entry()` / `to_dict()` so dashboards and any
   direct `results.json` consumers have one authoritative shape (coordinate with
   `metrics-extensibility-handoff.md` §6's score-entry normalization decision).

---

## 5. Registry alignment (agent resolution)

### 5.1 Problem

`resolve_agent` keeps a private path map and a legacy-alias map:

```python
_AGENT_MODULES = {
    "cli": "devops_bench.agents.cli.gemini",
    "binary": "devops_bench.agents.cli.gemini",
    "gemini": "devops_bench.agents.cli.gemini",
    "openclaw": "devops_bench.agents.cli.openclaw",
    "api": "devops_bench.agents.api.loop",
}
_AGENT_KEYS = {"cli": "gemini", "binary": "gemini"}
```

then `importlib.import_module(module_name)` to trigger `@AGENTS.register(...)`, then
`AGENTS.get(key)`. This is a **second registry layered on top of `AGENTS`** — the orchestrator
hardcodes module paths and legacy aliases that the registry is designed to own, partly
defeating the "drop in a module, decorate it, done" story that `metrics-extensibility-handoff.md`
§1 calls the high-leverage move.

### 5.2 Recommendation

- Resolve through `AGENTS` only. `devops_bench/core/registry.py` already supports
  `entry_point_group` + a thread-safe lazy `_ensure_entry_points_loaded()` — register the
  builtin agents as entry points (or import the builtin agent modules once at harness call
  time, the way `metrics-extensibility-handoff.md` §4.4 resolves the same import-ordering
  gotcha), so the harness never names module paths.
- Move the `cli` / `binary` → `gemini` aliases **into the registry** (register the same class
  under the alias keys, or normalize the env value to the canonical key in one place), out of
  the orchestrator.
- Net effect: adding or renaming an agent is a registry concern, with zero harness edits —
  consistent with how `agents-refactor-handoff.md` §6 wants the orchestrator to only *consume*
  the registry, not mirror it.

---

## 6. RunContext threading

### 6.1 Problem

`make_context` builds a `RunContext(task_id, task_name, cluster=...)`, but the abstraction is
only half load-bearing:

- `RunContext.workspace_path` and `RunContext.env` are never used; artifact snapshots run
  against cwd `"."`.
- The agent receives `{"cluster": context.cluster}` — a freshly-built dict — rather than the
  `RunContext` itself.

So the "state threaded across phases" promise the `RunContext` is meant to deliver is only
partially realized; it exists but does not yet carry the run.

### 6.2 Recommendation

- Use `context.workspace_path` (defaulting to cwd) for `snapshot_dir` / `collect_generated_files`
  (ties to §2 item 3), so a task can run in an isolated workspace.
- Pass the `RunContext` (or a typed slice of it) into the agent boundary instead of an
  ad-hoc `{"cluster": ...}` dict — coordinate with the agents refactor's `run(prompt)` /
  config split so the context is the single carrier of per-run state (cluster, workspace, env).

---

## 7. Config & capability ownership

### 7.1 Problem

The harness reads roughly seven environment variables inline — `BENCH_AGENT_TYPE`,
`AGENT_TARGET`, `APP_LOCATION`, `TARGET_DEPLOYMENT_NAME`, `NAMESPACE`, `BENCH_NO_TEARDOWN`, and
`BENCH_USE_MCP` (downstream in metrics). This is the same env-smuggling anti-pattern
`agents-refactor-handoff.md` §1 flags for agents, now at the orchestrator layer. Two
consequences:

- **The `BENCH_USE_MCP` regression is not closed here.** `agents-refactor-handoff.md` §6 and
  `metrics-extensibility-handoff.md` §4.3 want the *orchestrator* to read `BENCH_USE_MCP`
  **once**, thread it as `use_mcp` into the metric context, and have the agent's granted
  capabilities recorded — so agent and judge cannot disagree on whether tools were enabled.
  PR #10's `_score` just calls `evaluate_metrics_batch(scorable, judge_model)` and lets metrics
  re-read env, leaving the disagreement risk live.
- **No `capabilities_granted` record.** The harness does not own the GKE catalog / capability
  negotiation (`agents-refactor-handoff.md` §6) or record what each run was granted, so metrics
  cannot read `capabilities_granted` instead of re-reading env.

### 7.2 Recommendation

- Read `BENCH_USE_MCP` once in the harness and pass the resolved value to the scoring call
  (§2 item 2 is the minimal version).
- As the agents refactor lands, make the harness the single authority for building
  `AgentConfig` (incl. resolved capabilities) from *task requirements × run arm*, run
  capability negotiation, call `agent.run(prompt)`, and record `capabilities_granted` on the
  result — then thread that, not env, into the metric context.
- Longer term, collect the inline env reads into one config object so the user-facing run
  configuration is declared in one place rather than discovered by grep.

---

## 8. Reporting abstraction

### 8.1 Problem

`_write_results` (the `results.json` dump) and the artifact-copying live inside
`DefaultHarness`. `docs/interfaces.md` Layer 5 sketches a `ResultReporter` ABC; the metrics
handoff (`metrics-extensibility-handoff.md` §6, "Reporter abstraction") flags the same hardcoded
`json.dump` as the natural next extension axis. Output sinks (DB, dashboard, blob store) cannot
be added without editing the engine.

### 8.2 Recommendation

- Extract a thin `ResultReporter` (write JSON; collect artifacts) and have `DefaultHarness`
  depend on it, so the orchestration engine is decoupled from the output sink. Keep the default
  reporter byte-compatible with the current `results.json` layout to avoid a schema change
  (coordinate with §4.2 item 3).

---

## 9. Connection to the component refactors (seams to keep clean)

PR #10 must stay easy to retrofit once the sibling refactors land. The seams and the target
calls they should converge on:

### 9.1 Chaos (`chaos-refactor-handoff.md` §5.3)

- Today `scenario.py` rebuilds the chaos goal string inline (`_inject_fault` constructs the
  Fortio instruction) and hardcodes `_SUPPORTED_ACTION_TYPE = "generate_load"` plus the
  port-forward / service-URL specifics.
- Target: parse a typed `ChaosSpec`, then **`action.inject(ctx, chaos_active_event)`** — delete
  the inline goal-builder and the duplicate type-check, and build `chaos_report` from the
  returned `ChaosResult`. Keep the trigger-delay / port-forward / URL-rewrite logic factored so
  it can move into `faults/generate_load.py` without touching the harness control flow.

### 9.2 Verification (`verification-spec-redesign-handoff.md` §7c)

- Today `run_chaos_and_verification` resolves `spec.get("verification")` by **scanning a list**
  for a matching `name` (or inlining a dict).
- Target: change the lookup to a **mapping** (`registry.get(ref)`), pass the resolved typed
  node straight to `wait_for_condition`, and consume the typed `VerificationResult`
  (`success`, `elapsed_time`, `children`, `raw`) instead of `model_dump()` into a dict. Keep
  the verification-timeout budget (`VERIFICATION_TIMEOUT_SEC`, and the harness's
  `_SCENARIO_JOIN_SEC = VERIFICATION_TIMEOUT_SEC + 60`) sourced from one place so the single
  monotonic-deadline model the verification handoff introduces stays authoritative.

### 9.3 Metrics (`metrics-extensibility-handoff.md` §4.3)

- Today `_score` calls `evaluate_metrics_batch(scorable, judge_model)`.
- Target: the harness owns the single `BENCH_USE_MCP` read (§7) and passes `use_mcp` into the
  `MetricContext` the metrics registry loop builds; adding a metric remains zero harness edits.

### 9.4 Agents (`agents-refactor-handoff.md` §6)

- Today resolution is the `_AGENT_MODULES` map + `agent.run(prompt, {"cluster": ...})` →
  result dict.
- Target: registry-only resolution (§5), harness-built `AgentConfig` with resolved
  capabilities (§7), `agent.run(prompt) → AgentResult`, and `capabilities_granted` recorded on
  the result.

---

## 10. Flagged decisions & acceptance

### Flagged decisions (do not silently choose — owned by the separate sequencing plan)

- **Merge order.** Two coherent options: **(a)** merge PR #10 now as a declared
  behavior-preserving port with §4–§9 as *committed* immediate follow-ups (open tracking
  issues referencing the section anchors above), or **(b)** land the verification / chaos /
  metrics / agents refactors first so the harness is born consuming clean interfaces. The stack
  is already built bottom-up, which favors (a) — but only if the follow-ups are tracked, not
  aspirational. This decision is deferred to the cross-cutting sequencing plan.
- **Results schema.** Typing the seams (§4) and extracting the reporter (§8) eventually touch
  the `results.json` shape; whether to preserve the legacy mixed shape or normalize is a
  shared decision with `metrics-extensibility-handoff.md` §6. Default: preserve.

### Acceptance

- `ruff check` clean; `pytest tests/unit/harness` green (the suite mocks `ChaosAgent` /
  `VerifierAgent` / deployer / subprocess).
- **§2 item 1:** a test asserting agent resolution goes through `AGENTS` (e.g. a dummy
  `@AGENTS.register("dummy")` agent resolves) **with no `_AGENT_MODULES` entry**.
- **§4:** a `Task`-in round-trip test — a typed `Task` (with `prompt`, `chaos_spec`) flows
  through `run()` and produces a scored result, exercising the `input`/`prompt` migration.
- **§2 item 2 / §7:** a test that `BENCH_USE_MCP` is read once by the harness and the same value
  reaches scoring (agent and judge cannot disagree).
- Grep shows the harness names no agent module paths and reads `BENCH_USE_MCP` in exactly one
  place.

---

## 11. File-by-file change list

| File | Section | Change |
|---|---|---|
| `harness/default.py` | §2.1, §5 | Replace `_AGENT_MODULES` / `_AGENT_KEYS` + `importlib` dance with `AGENTS`-only resolution (entry points / one-time builtin import); move `cli`/`binary` aliases into the registry. |
| `harness/default.py` | §2.2, §7 | Read `BENCH_USE_MCP` once; pass `use_mcp` to the scoring call; (later) own `AgentConfig` + capability negotiation and record `capabilities_granted`. |
| `harness/default.py` | §2.3, §6 | Use `RunContext.workspace_path` for snapshot/artifacts; pass `RunContext` to the agent boundary instead of `{"cluster": ...}`. |
| `harness/default.py` | §2.4, §4 | Single prompt accessor; migrate `run()` to accept the typed `Task` (PR #89), fixing the `input`/`prompt` mismatch; return typed results. |
| `harness/scenario.py` | §9.1, §9.2 | (Follow-up) Drive faults via `action.inject(ctx, event)` and delete the inline goal-builder; change verification lookup from list-scan to mapping; consume typed `ChaosResult` / `VerificationResult`. |
| `harness/artifacts.py` | §2.3, §6 | Accept the workspace path from `RunContext` rather than assuming cwd. |
| `harness/base.py` | §4 | (Follow-up) Tighten the `Harness.run` signature toward typed `Task` in / typed result out. |
| new: `harness/reporter.py` (or `core`) | §8 | (Follow-up) Thin `ResultReporter` (JSON dump + artifact collection) the engine depends on. |
| `tests/unit/harness/*` | §10 | Add the registry-resolution, typed-`Task` round-trip, and single-`BENCH_USE_MCP`-read tests. |
