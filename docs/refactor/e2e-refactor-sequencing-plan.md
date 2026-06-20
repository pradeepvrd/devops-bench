# E2E Refactor Sequencing Plan

**Audience:** owner/maintainer sequencing the harness refactor across the five
`docs/refactor/*-handoff.md` documents and the four open Stage 1 PRs (#89–#92).
**Status:** planning document. Synthesizes and reconciles the five component
handoffs into one ordered, decoupling-maximizing landing plan, and audits the open
PRs for changes required to make the downstream refactors land cleanly.

The five handoffs are deliberately written as independent component docs. This plan
is the missing **cross-cutting sequencing layer** that each of them explicitly defers
to (e.g. `harness-refactor-handoff.md` §10 "deferred to the cross-cutting sequencing
plan"; `metrics-extensibility-handoff.md` §6 "Sequencing").

---

## 1. Context — why this plan exists

The harness is being migrated from a legacy monolith (`pkg/evaluator/evaluate.py` +
`pkg/manager/manager.py` + `pkg/agents/*` + top-level `deployers/`) into a layered
`devops_bench/` package. The migration is happening as **two PR chains**:

- **Stage 1 (foundation leaves) — gke-labs `main` PRs, OPEN now:**
  - #84 `core` (merged) — `Registry`, `RunContext`, `ClusterInfo`, `Result`/`Status`,
    errors, config helpers, logging, `subprocess.run`.
  - #89 `tasks` · #90 `deployers`/`providers` · #91 `k8s` · #92 `models`.
- **Stage 2/3 (components + orchestrator) — fork PRs #5–#10**, being *reworked* per
  the five handoffs before being retargeted to `gke-labs/main`:
  - verification (#6), chaos (#7), agents (#5/#9), metrics (#8) → Stage 2;
  - harness (#10) → Stage 3.

The pipeline these assemble is, end to end:

```
tasks → deployers → k8s ─┐
                         ├─► harness orchestrator ─► metrics/report
models → agents          │        ▲   ▲
       └► chaos ──────────┘        │   │
              verification ────────┘   │
                                       └─ results.json
```

**Concerns to preserve throughout (the acceptance bar for every PR):**

1. **Simplicity of API** — thin, typed seams; no env-smuggling; no hand-rolled dicts.
2. **Maintainability** — one consistent "drop in a module, decorate it, done"
   extension story (registries) across agents/tasks/metrics/verifiers/faults.
3. **Architectural correctness** — strict layering; a higher layer may depend on a
   lower one, never the reverse; shared utilities sink to the lowest common layer.
4. **Clear separation along dimensions** — transport vs. capability vs. arm (agents);
   spec vs. result vs. runner (verification/chaos); engine vs. sink (reporter);
   structure vs. metadata (no `name` double-duty).

---

## 2. The layering model (the invariant the sequence must respect)

```
Layer 0  core/                         Registry, RunContext, ClusterInfo, Result, subprocess
            ▲
Layer 1  tasks/  deployers/  k8s/  models/        (the four OPEN PRs — pure leaves)
            │                          │
            │                          └── models/loop.py   (run_tool_loop — see §4.1)
            ▲
Layer 2  verification/   chaos/   agents/   metrics/        (Stage 2 components)
            ▲
Layer 3  harness/                                            (orchestrator + reporter)
```

**Hard rules (enforce in review):**

- Layer-1 leaves import **only** `core` (and, for `deployers`, its sibling `providers`,
  which itself imports only `core`). They must **not** import each other. *(Verified
  clean today across #89–#92.)*
- Layer-2 components import Layer-1 + `core`, **never each other**. The one place this
  is at risk is the shared agent/chaos turn-loop — resolved in §4.1 by sinking it to
  Layer 1 (`models/loop.py`), the design-legal home (`chaos-refactor-handoff.md` §3
  cites migration §1.7/§5: "shared utilities sink to a lower layer").
- Layer-3 (`harness`) is the only place allowed to wire components together, and it
  must do so by **consuming registries**, never by mirroring module paths
  (`harness-refactor-handoff.md` §5).
- The Task schema's `chaos_spec`/`verification_spec` stay **opaque** at Layer 1 — typing
  them with Stage-2 schemas would invert the layering (Layer 1 → Layer 2). Stage 2
  parses the opaque blob at its own boundary. *(Verified: #89 keeps them `Any`.)*

---

## 3. Verdict on the open PRs (#89–#92) — do they need changes?

**Headline:** the four leaves are already exemplary, fully decoupled single-responsibility
modules (zero cross-imports; each imports only `core`). **None requires a structural
change to make the downstream refactors correct.** The only substantive *foundation*
work the refactors imply is **additive** (one new file in `models/`), plus a small
amount of **contract hardening** (documenting shapes that downstream will depend on
byte-for-byte). Details per PR:

### 3.1 #92 `models` — two additive items (not blockers to merging #92 as-is)

`models` is the one leaf that must **grow** to support Stage 2, because both the API
agent and the chaos agent run an identical LLM tool-use loop.

- **(REQUIRED, additive) Add `devops_bench/models/loop.py`** — `run_tool_loop()` +
  `LoopResult` + `ToolDispatcher` (spec in `chaos-refactor-handoff.md` §5.1). This is
  the single highest-leverage decoupling move in the whole plan (see §4.1). It belongs to
  the **models layer**, not to agents or chaos.
  - **Recommended: fold it into #92 itself** rather than a new PR. It imports only
    `models.base` + `core`, so it is legitimately part of this PR's package, and "lands
    when #92 lands" satisfies the only sequencing constraint (exist before agents-PR2 and
    chaos). Two caveats: **(a)** relabel #92 from "LLM client adapters" to "models layer
    (adapters + shared turn-loop)" so the added primitive + tests are expected, not scope
    creep; **(b)** because the loop's two consumers (`agents/api/loop.py`, `chaos/agent.py`)
    are not on `main` yet, you commit to its contract ahead of them — mitigate by following
    §5.1 exactly and **locking its one open decision now: the caller formats tools** (the
    primitive stays ignorant of provider tool-descriptor shapes). A tiny stacked PR off #92
    is the only-if-you-prefer alternative; not required.
  - *No change to the existing `LLMClient` ABC is needed to host it.* Verified: the ABC
    already exposes `async generate_content(contents, system_instruction, …)`,
    `format_tools`, `extract_function_calls`, `get_text_content`, and all three adapters
    already speak the neutral `{role, content, tool_calls, tool_call_id}` message shape
    the loop requires.
- **(RECOMMENDED) Freeze & document the neutral message/tool-result contract** in
  `models/base.py`. Today it lives only as an in-passing docstring ("Neutral message
  dicts with `role` and `content` keys") and as the *de facto* behavior of the three
  adapters. Because `run_tool_loop` + the API agent + the chaos agent will all depend on
  the exact shapes —
  - assistant turn: `{"role":"assistant","content":text[,"tool_calls":[{name,args,id}]]}`
  - tool result: `{"role":"tool","tool_call_id":id,"name":name,"content":result}`
  — promote these to an explicit documented contract so the loop and its consumers can
  not drift. Pure documentation/typing; no behavior change.
- **(CONFIRM) `get_model(provider, model_name)` takes explicit args** so callers own env
  precedence — chaos selects via `first_env("CHAOS_PROVIDER","AGENT_PROVIDER")`, agents
  via `AGENT_PROVIDER`. Verified present; no change.

### 3.2 #89 `tasks` — no structural change; one coordinated decision

- **Keep `chaos_spec`/`verification_spec` as opaque `Any`.** Verified:
  `_STRICT = ConfigDict(strict=True, extra="ignore")`, fields `chaos_spec: Any = None`
  / `verification_spec: Any = None`, with a dedicated `test_*_specs_are_opaque`
  asserting both string and list/dict pass through untouched. This is exactly the right
  decoupling — do **not** type them with `ChaosSpec`/`VerificationSpec`.
- **Watch the `extra="ignore"` + explicit-key-mapping interaction.** `load_tasks` reads
  these keys explicitly (`raw.get("chaos_spec")`, `raw.get("verification_spec")`), and
  unknown top-level keys are silently dropped. So if Stage 2 Phase B renames the task
  fields to `verifications:`/`chaos:` (suggested in `verification-spec-redesign-handoff.md`
  §7b and `chaos-refactor-handoff.md` §6), the loader **and** schema must be updated in
  lockstep — otherwise the new keys vanish.
  - **Recommendation:** keep the field *names* `chaos_spec`/`verification_spec` and change
    only their *values* from JSON-in-YAML strings to native YAML (both are valid `Any`).
    This yields **zero churn in #89** while still landing the verification/chaos UX win.
    Treat the prettier `verifications:`/`chaos:` rename as an optional, separately-decided
    follow-up (§7, Decision D2).
- **`input`/`prompt` mismatch is already handled by #89** (accepts `input`/`goal` aliases
  for `prompt`). The fix for the live mismatch lives on the **harness** side
  (`harness-refactor-handoff.md` §2.4/§4) — #89 needs nothing.

### 3.3 #91 `k8s` — no change; confirmed sufficient for Stage 2 verifiers

The verifier redesign builds `PodHealthyVerifier`/`ScalingCompleteVerifier` on generic
k8s primitives. Verified that #91 provides exactly what they need:

- `poll_until(predicate, *, timeout_sec: float, …)` — a verifier can spend the
  single-monotonic-deadline budget by passing its handed `remaining` seconds straight in.
- `get_resource(resource, name?, *, selector, namespace) -> dict` — selector/namespace
  args present; returns parsed JSON for the predicate to inspect.
- `wait`, `rollout_status`, `apply` — all take `timeout_sec`/`namespace`.
- **Readiness predicates correctly deferred to `verification/verifiers/` (Stage 2).** This
  is the correct split: generic primitives at Layer 1, domain predicates at Layer 2.
- *(Minor, for the verifier author, not #91):* `get_resource` returns raw kubectl JSON, so
  verifiers must null-guard `.status` (the `status: null → AttributeError` bug flagged in
  `master_review_report.md`). This is a Stage-2 verifier concern.

### 3.4 #90 `deployers`/`providers` — no change

No handoff touches deployers. The harness already consumes `deployers.factory.get_deployer`
(`harness-refactor-handoff.md` §1 "keep it"); `get_cluster_info()` returns `core.ClusterInfo`,
which the `RunContext` carries. The most independent leaf — leave it.

### 3.5 Merge order among #89–#92

They are independent leaves with no cross-imports, so **any order works and they can land
in parallel.** Recommended for narrative clarity: #89 → #90 → #91 → #92, then the
`models/loop.py` follow-up (§4.1). Keep them mergeable in parallel; the one thing to guard
in review is that **no leaf grows an import of a sibling leaf.**

---

## 4. Cross-document interactions to resolve (these drive the sequence)

### 4.1 The agents ↔ chaos shared loop — the central decoupling decision

Both `agents/api/loop.py` and `chaos/agent.py` run the same model-agnostic tool-use loop.
The two handoffs handle this **inconsistently**:

- `chaos-refactor-handoff.md` §5.1–§5.2 says: extract `models/loop.py::run_tool_loop`
  and refactor **both** `agents/api/loop.py` and `chaos/agent.py` onto it.
- `agents-refactor-handoff.md` (PR2, §4) reworks `agents/api/loop.py` onto the new
  `AgentHarness`/`AgentResult` but **does not mention** the shared primitive.

If left unreconciled, `agents/api/loop.py` gets reshaped **twice** (once by agents-PR2,
again by chaos Phase A), and agents/chaos risk a sibling import.

**Decision (D1, recommended): elevate `run_tool_loop` to a Layer-1 deliverable**, landed
**before** both agents-PR2 and chaos Phase A. Preferred home is **#92 itself** (fold it in
and relabel the PR; see §3.1) since it is models-layer code and lands in time by definition;
a small stacked PR off #92 is the alternative. Then:

- `agents/api/` (PR2) builds its loop on `run_tool_loop` from the start (one reshaping).
- `chaos/agent.py` consumes the same primitive.
- Agents and chaos become **true siblings**: both depend on `models`, neither on the other.

This is the cleanest expression of "each PR as decoupled as possible." It requires a minor
amendment to the agents handoff (PR2 consumes `run_tool_loop` rather than carrying its own
loop) — call it out in the PR2 description.

### 4.2 Verification ↔ chaos: decoupled packages; what actually needs ordering

**The two packages are fully decoupled — neither imports the other.** Verification depends
on `k8s` (#91) + core (deterministic kubectl polls); chaos depends on `models/loop.py` +
core (an LLM loop). They share no Layer-1 dependency. The only link is
`ChaosSpec.verify: str | None`, an **opaque reference key** — chaos never constructs or
imports a verification node; the **harness** resolves the key against the verification
registry (`scenario.py: registry.get(ref) → wait_for_condition`). Wiring siblings together
is the harness's job by design.

So the "ordering" between them is **not a package dependency.** It comes from three distinct
places, only one of which is a hard dep, and none of which is chaos importing verification:

1. **Soft — shared pattern template.** `chaos-refactor-handoff.md` says "read [verification]
   first — chaos must end up structurally consistent." This is a *consistency* concern (same
   discriminated-union + typed-result + registry idiom), not code coupling. Parallelizing
   risks **divergence**, not breakage. Mitigation: agree the node/result/registry conventions
   up front, then both follow them.
2. **Hard, but transitive and chaos-free.** The **verifier registry**
   (`metrics-extensibility-handoff.md` §5) must land after the verification redesign — a
   verification → metrics ordering. Chaos is not in this chain.
3. **Real, but harness-located.** Two Layer-3 / task-file touchpoints — the *harness half* of
   authoring UX (§4.6) — need both components wired: `harness/scenario.py` resolves chaos's
   `verify:` against the verification registry mapping (§9.1+§9.2), and the single
   `optimize-scale/task.yaml` migration carries a chaos→verification cross-reference
   (`verify: planned_load_spike` → a `verifications:` key).

⇒ **Run verification Phase A and chaos Phase A in parallel** (fix conventions first to avoid
divergence). **Order only the Phase-B touchpoint:** land verification's `verifications:`
mapping before/with chaos's `verify:` reference, and do the `task.yaml` migration +
`scenario.py` wiring once both Phase A's are in. Verification still precedes the **verifier
registry** (metrics Phase 3).

### 4.3 `BENCH_USE_MCP` single source of truth (three-way cut)

`agents-refactor-handoff.md` §6 + `metrics-extensibility-handoff.md` §4.3 +
`harness-refactor-handoff.md` §2.2/§7 all describe the same regression: agent and judge can
disagree on whether tools were enabled. Closure is staged:

1. **Minimal (early):** harness reads `BENCH_USE_MCP` once and threads the boolean into the
   scoring call / `MetricContext.use_mcp` (`harness` §2 item 2).
2. **Full (after agents PR3):** harness builds `AgentConfig` (incl. resolved capabilities),
   records `capabilities_granted` on the result, and metrics read *that* instead of env.

### 4.4 The harness dict-junction & `results.json` schema

The harness is where every typed contract currently collapses to `dict`
(`harness-refactor-handoff.md` §4). It is retrofitted **incrementally** as each Layer-2
component grows its typed result (`AgentResult`, `ChaosResult`, `VerificationResult`,
`MetricScore`). The on-disk `results.json` shape is a shared contract between `harness` §8
and `metrics` §6 — **default: preserve** the legacy mixed shape via `MetricScore.to_entry()`
/ `*.to_dict()` (Decision D3, §7).

### 4.5 Registry-only resolution everywhere

The maintainability goal ("drop in a module, decorate it, done") requires the registry
pattern on **all** extension axes. Today it's wired for `AGENTS`/`TASKS`; the refactors add
it for `METRICS`, `VERIFIERS`, and `FAULTS`/`TRIGGERS`, and remove the harness's parallel
`_AGENT_MODULES` dispatch table (`harness` §5).

### 4.6 "Authoring UX" splits into a component half and a harness half

Both the verification (§7) and chaos (§6) handoffs bundle "authoring UX" into their Phase B,
but it is **two separable concerns at different layers**, and only one is component-ownable:

- **Component half — the authoring *contract* (belongs in each component PR, independently).**
  The spec models accept native YAML and validate at author time (already delivered by the
  Phase-A discriminated unions), plus JSON-Schema emission / a `validate-task` command
  (`verification` §7d) and a **regression test that a literal of the real task spec parses and
  discriminates correctly**. None of this reads a task file or touches the harness ⇒ it ships
  in the verification PR and the chaos PR, fully decoupled.
- **Harness half — task-file migration + reference resolution (belongs in the harness step).**
  Editing the shared `optimize-scale/task.yaml`, making the per-task verification registry a
  **name-keyed mapping**, resolving chaos's `verify:` key against it, and `scenario.py` driving
  `action.inject`/`trigger.wait`. This is intrinsically Layer 3: the harness is the only
  component that reads task files and wires siblings, and the task.yaml is one file carrying
  both the `verifications:` and `chaos:` blocks plus their cross-reference.

⇒ **Add the authoring *contract* to each component PR; consolidate the task-file *migration +
wiring* into the harness step (§9.1/§9.2).** This also dedups the overlap where the component
handoffs *and* the harness handoff each claim `scenario.py`/`task.yaml` — the harness owns
them. Keeping chaos's `verify:` a plain **key** (not an inline verification node) is what lets
the two component halves stay independent; an inline node would force `chaos` to import
`verification`.

---

## 5. The end-to-end sequenced plan

Phases are ordered by dependency. Items **within** a phase are parallelizable. Each box
notes its dependency and the decoupling rationale.

### Phase 0 — Land the Stage 1 foundation (OPEN PRs #89–#92)

- Merge #89, #90, #91, #92 (any order / parallel). **No structural changes** (§3).
- Apply the small additive/doc items to #92: document the neutral message contract (§3.1).
- **Exit criteria:** four leaves on `main`, each importing only `core` (+ `providers` for
  `deployers`); full unit suite + ruff green.

### Phase 1 — Models loop primitive (Stage 1.5) **[Decision D1]**

- Add `devops_bench/models/loop.py` (`run_tool_loop`, `LoopResult`, `ToolDispatcher`),
  imports only `models.base` + `core`. Caller formats tools (keeps the primitive ignorant
  of descriptor shapes).
- **Preferred packaging: fold into #92** (relabel it "models layer: adapters + shared
  loop") so this is not a separate PR; the sequencing requirement is only "before
  agents-PR2 and chaos," which #92 meets by definition. See §3.1 / D1 for the two caveats.
- **Dependency:** #92 (or merged into it). **Decoupling:** makes agents and chaos siblings (§4.1).
- **Exit criteria:** primitive unit-tested in isolation (turn-cap, final-text retention on
  every turn, latency accumulation, dispatch error surfacing).

### Phase 2 — Verification redesign (`verification-spec-redesign-handoff.md`)

- **2A (engine + node shape, no task-file churn):** discriminated-union spec
  (`SequenceSpec`/`ParallelSpec` + `name`-bearing leaves), typed `VerificationResult`
  (`children`/`raw`, drop `details`), single-monotonic-deadline `VerifierAgent`
  (keep `wait_for_condition(spec, timeout_sec=120)` signature). Verifiers consume #91 k8s.
- **2B (authoring *contract* — stays in the verification PR):** the 2A spec models already
  validate native YAML; add the self-contained wins that touch no task file or harness —
  `VerificationSpec.model_json_schema()` emission / a `validate-task` command (§7d) and a
  **regression test that a literal of the real `optimize-scale` spec parses and dispatches**
  (leaf `verify` stubbed). See §4.6.
- **2C (task-file + harness wiring — moves to Phase 5):** name-keyed **mapping** registry,
  `scenario.py` lookup list-scan → `registry.get(ref)`, and the `optimize-scale/task.yaml`
  migration. Harness-owned (§4.6, §9.2); **not** in the component PR.
- **Dependency:** #91 (k8s), #84 (core). Independent of agents/chaos/metrics.
- **Decoupling:** the structural template that chaos mirrors and the verifier registry
  extends (§4.2).

### Phase 3 — Agents refactor (3 stacked PRs) + Chaos refactor (parallel)

Agents and chaos run **in parallel** once Phase 1 exists (both consume `run_tool_loop`).
Chaos Phase A can also run **in parallel with verification Phase 2A** — the only link is a
shared *pattern*, so either agree the node/result/registry conventions up front, or let
Phase 2A land first as the template to copy (see §4.2). Only the Phase-B wiring is ordered.

- **Agents (`agents-refactor-handoff.md`):**
  - **PR1** — `AgentHarness` template + `AgentConfig` + `AgentResult`/`ToolCall`; rewrite
    `cli/gemini.py` & `cli/openclaw.py`; canonical trajectory via official channels
    (stream-json / `sessions export-trajectory`); delete `run_cli_agent`, SSH, hardcoded
    GKE tool list. *Depends only on `core` (+ binaries).*
  - **PR2** — `agents/api/` onto base/config/result **and onto `models/loop.py`** (amend
    per D1); canonical trajectory; decouple skills from MCP; drop `context`/
    `system_instruction`; stop self-reading `BENCH_USE_MCP`. *Depends on #92 + Phase 1.*
  - **PR3** — `agents/capabilities/` (Protocols/mixins + `McpBinding`/`SkillBinding`/
    `AgentRules`); each agent *consumes* bindings; no GKE strings anywhere in `agents/`.
- **Chaos (`chaos-refactor-handoff.md`):**
  - **Phase A** — `ChaosAgent` onto `run_tool_loop`; typed `ChaosResult`; `type`-tagged
    `Fault`/`Trigger` nodes + `ChaosSpec`; move fortio specifics into
    `faults/generate_load.py`; new `triggers/time_delay.py`; slim `__init__`; one-way
    imports. *Depends on Phase 1 + Phase 2A (template) + `core.RunContext`.*
  - **Authoring *contract* (stays in the chaos PR):** `ChaosSpec` already validates native
    YAML (Phase A); add the **regression test that a literal of the real `optimize-scale`
    chaos entry parses** and discriminates to `GenerateLoadFault`/`TimeTrigger`. No task
    file, no harness. See §4.6.
  - **Task-file + harness wiring (moves to Phase 5):** the `optimize-scale/task.yaml`
    migration and `scenario.py` driving `trigger.wait(ctx)` + `action.inject(ctx, event)` →
    `ChaosResult` report, with `verify:` resolved against the verification mapping.
    Harness-owned (§4.6, §9.1); needs verification's mapping (2C) in place.

### Phase 4 — Metrics extensibility (`metrics-extensibility-handoff.md`)

- **Phase 0 fixes (can land as early as Phase 2):** `CHECKLIST_THRESHOLD`, delete dead
  grounding branches, shared `run_geval` recorder, `extract_checklist_items` visibility,
  reviewer note. *Independent.*
- **Metrics registry:** `metrics/base.py` (`METRICS`, `MetricScore`, `MetricContext`,
  `run_geval`); wrap each family as a registered `MetricEvaluator`; collapse
  `evaluate_metrics_batch` to the registry loop; import builtins at call time (§4.4 of that
  doc). `use_mcp` arrives via `MetricContext` (single read owned by harness, §4.3).
- **Verifier registry:** `VERIFIERS` registry + registry-driven `VerificationSpec` parsing;
  drop the static union. *Depends on Phase 2.*

### Phase 5 — Harness convergence (`harness-refactor-handoff.md`)

- **§2 cleanups (early, behavior-neutral — can land alongside Phase 0/2):** registry-only
  agent resolution (remove `_AGENT_MODULES`/`_AGENT_KEYS`); single `BENCH_USE_MCP` read;
  `RunContext.workspace_path` for artifacts; single prompt accessor.
- **Typed-seam retrofits (each gated on its component):**
  - §9.4 agents → after agents PR3 (`agent.run(prompt)→AgentResult`, `capabilities_granted`).
  - §9.1 chaos → `action.inject`/`trigger.wait`, `ChaosResult`, **+ the chaos `task.yaml`
    migration** (the harness half of chaos authoring UX, §4.6); after chaos Phase A.
  - §9.2 verification → name-keyed **mapping** lookup, typed `VerificationResult`, **+ the
    verification `task.yaml` migration** (§4.6 / step 2C); after verification Phase 2A. Land
    the `verifications:` block before/with chaos's `verify:` reference (§4.2).
  - §9.3 metrics → after metrics registry (thread `use_mcp` into `MetricContext`).
  - §4 `run(list[Task])` typed-in/typed-out; §8 extract `ResultReporter`.
- **Decoupling:** the harness ends as a pure wiring layer — consumes registries + typed
  contracts, owns config/env reads, names no module paths.

### Dependency DAG (text form)

```
#84 core
 ├─ #89 tasks ───────────────────────────────────────────────┐
 ├─ #90 deployers/providers ─────────────────────────────────┤
 ├─ #91 k8s ──────────────► Phase 2 verification ─┬─► metrics verifier-registry
 └─ #92 models ─► Phase 1 models/loop.py ─┬─► agents PR1/PR2/PR3 ─┐
                                          └─► chaos Phase A/B ────┤
                                                                  ▼
                          metrics Phase0 + registry ───────► Phase 5 harness convergence
```

---

## 6. Decoupling principles to enforce across the chain

1. **Shared utilities sink to the lowest common layer** — the agent/chaos loop lives in
   `models/`, not in either consumer (§4.1).
2. **Opaque blobs at layer boundaries** — `Task.chaos_spec`/`verification_spec` stay `Any`;
   each component parses its own typed nodes (§3.2).
3. **Domain predicates build on generic primitives** — verifiers use `k8s.poll_until` /
   `get_resource`; no duplicated kubectl logic (§3.3).
4. **Registry-only resolution** — agents/metrics/verifiers/faults/triggers self-register;
   the harness mirrors no module paths (§4.5).
5. **One env read, threaded** — harness owns `BENCH_USE_MCP` (and the capability arm);
   agents/metrics stop self-reading it (§4.3).
6. **Typed contracts at every seam** — `Task`, `AgentResult`, `ChaosResult`,
   `VerificationResult`, `MetricScore`; the harness dict-junction dissolves (§4.4).
7. **Light `__init__`, lazy heavy imports** — `import devops_bench.<pkg>` pulls no provider
   SDK / `deepeval` / `mcp` and no concrete implementation.

---

## 7. Flagged decisions (resolve before/at the relevant phase)

- **D1 — Loop-primitive ownership *(recommended: Layer 1, folded into #92, before
  agents-PR2 & chaos)*.** Add `run_tool_loop` to `models/loop.py` so agents and chaos never
  co-edit `agents/api/loop.py` and never import each other (§4.1). **Fold it into #92**
  (relabel the PR; lock "caller formats tools") rather than spawning a new PR — a stacked
  follow-up off #92 is the alternative if you prefer to keep #92 adapters-only (§3.1).
- **D2 — Task field rename *(recommended: keep names, change values only)*.** Keep
  `chaos_spec`/`verification_spec`; switch values to native YAML → zero #89 churn. Only
  rename to `verifications:`/`chaos:` if the UX win is judged worth a coordinated
  schema+loader+harness change (§3.2).
- **D3 — `results.json` schema *(recommended: preserve)*.** Route typed results through
  `to_entry()`/`to_dict()` to keep the on-disk shape stable; normalize only with a reviewer
  note + consumer updates (§4.4; `metrics` §6; `harness` §8).
- **D4 — Harness merge order *(recommended: option a, behavior-preserving port now +
  tracked follow-ups)*.** The stack is built bottom-up and the leaves are clean, so land
  PR #10 as the declared behavior-preserving port and retrofit typed seams per Phase 5 —
  **only if** the follow-ups are tracked as committed issues (per `harness` §10), not
  aspirational, so the dict-seams don't ossify.
- **D5 — Metric-score normalization *(recommended: defer)*.** Keep `MetricScore.to_entry()`
  mixed shape now; normalizing to one dict shape is a separate output-schema change
  (`metrics` §6).

---

## 8. Verification / acceptance (per phase)

- **Per PR (invariant):** `ruff check` clean; full unit suite green; the tree is never left
  broken between stacked PRs; `import devops_bench.<pkg>` pulls no SDK/concrete.
- **Phase 0:** grep shows no leaf imports another leaf; #92 documents the neutral message
  contract.
- **Phase 1:** `run_tool_loop` unit-tested standalone; turn-cap + final-text retention +
  latency accumulation covered.
- **Phase 2:** the real `optimize-scale` verification spec parses and dispatches (regression
  test); parallel children each see the full remaining deadline; sequence fail-fast skips
  the rest; one clock source (`time.monotonic`).
- **Phase 3 (agents):** both CLI agents + API agent emit the canonical `ToolCall`
  trajectory from official channels; no SSH / `run_cli_agent` / GKE strings; timeouts on
  every external call. **(chaos):** real `optimize-scale` chaos entry parses to typed
  fault/trigger; no bare-dict `Fault.inject`; no duplicate turn-loop / fortio constants in
  `agent.py`; `agents/api/` trajectory/tokens/latency byte-identical after loop extraction.
- **Phase 4:** a dummy `@METRICS.register("dummy")` appears in `res["scores"]` with **no
  edit** to `evaluate_metrics_batch`; a dummy `@VERIFIERS.register("dummy_check")` parses
  with **no union edit**; the ` [GEval]` strip lives only in `run_geval`.
- **Phase 5:** a dummy `@AGENTS.register("dummy")` resolves with **no `_AGENT_MODULES`
  entry**; a typed `Task` (with `prompt`, `chaos_spec`) round-trips through `run()` to a
  scored result; `BENCH_USE_MCP` is read in exactly one place and the same value reaches
  agent and judge.
- **E2E smoke (after Phase 5):** run `complextasks/optimize-scale` against the `NoOpDeployer`
  / a kind cluster with `deepeval`/SDKs stubbed where possible; confirm one `results.json`
  with the preserved schema, a populated trajectory, and chaos+verification reports.

---

## 9. Risk register

| Risk | Phase | Mitigation |
|---|---|---|
| Agents & chaos co-edit `agents/api/loop.py`, or grow a sibling import | 1/3 | Land `models/loop.py` first (D1); review-gate sibling imports. |
| Stage-2 task-file rename silently drops keys (`extra="ignore"`) | 2C / §9.1 | Keep field names (D2); if renaming, update loader+schema+harness in one PR. |
| Harness dict-seams ossify because everything green-lights against them | 5 | Adopt D4 *only* with tracked, committed follow-ups (one per §-anchor). |
| Verifier registry attempted before the spec redesign | 4 | Enforce ordering: Phase 2 before the verifier registry (`metrics` §5). |
| `results.json` schema drift between metrics & harness | 4/5 | Single decision D3; route all on-disk writes through typed `to_entry()`/`to_dict()`. |
| Verifier `.status` null crash on real clusters | 2 | Null-guard in the verifier (not k8s); covered by a verifier unit test. |
| CLI trajectory parsers break on installed-binary schema drift | 3 | Verify flags/schemas against installed `gemini`/`oc`; record misses in `AgentResult.errors`, never silent-empty. |

---

## 10. TL;DR

- **The four open leaves (#89–#92) are correctly decoupled and need no structural change.**
  The only foundation work the refactors require is **additive**: a shared
  `models/loop.py` turn-loop primitive (Decision D1) plus documenting #92's neutral message
  contract. Keep #89's specs opaque and its field names stable (D2) for zero churn.
- **Order:** foundation (#89–#92) → `models/loop.py` → verification → {agents ∥ chaos} →
  metrics → harness convergence. Verification anchors chaos and the verifier registry;
  the harness lands its behavior-neutral cleanups early and absorbs typed seams last.
- **The decoupling lever** that keeps the chain clean is sinking the shared loop to the
  models layer so agents and chaos are siblings, plus registry-only resolution and a single
  env source-of-truth so the harness is pure wiring.

---

## 11. Exact PR list

Recommended landing order, **with `models/loop.py` as a small stacked PR on #92** (the
alternative to folding it into #92 per D1). Legend: **OPEN** = already open on `gke-labs/main`;
**rework** = the reworked form of an existing fork PR; **new** = does not exist yet.

| # | PR | Scope | Origin | Lands after |
|---|----|-------|--------|-------------|
| **Stage 1 — foundation** |
| 1 | `feat(tasks)` | Task schema + loader (specs stay opaque) | **#89 OPEN** | #84 |
| 2 | `feat(deployers)` | OpenTofu/NoOp deployers + providers | **#90 OPEN** | #84 |
| 3 | `feat(k8s)` | kubectl wrappers + `poll_until` | **#91 OPEN** | #84 |
| 4 | `feat(models)` | `LLMClient` adapters + `MODELS` + neutral-message contract docs | **#92 OPEN** | #84 |
| **Stage 1.5 — shared loop** |
| 5 | `feat(models): run_tool_loop` | `models/loop.py` (`run_tool_loop`, `LoopResult`, caller-formats-tools) | **new**, stacked on #92 | 4 |
| **Stage 2 — components** |
| 6 | `feat(verification)` | spec redesign + deadline runner + typed result + **authoring contract** (2A+2B) | **rework #6** | 3 |
| 7 | `feat(agents): base + cli` | `AgentHarness`/`AgentConfig`/`AgentResult`; gemini+openclaw; no SSH/dispatch | **rework #5** | 1 (core) |
| 8 | `feat(agents): api` | `ApiAgent` on base + on `run_tool_loop`; skills⊥MCP; no env-smuggling | **rework #9**, stacks on 7 | 5, 7 |
| 9 | `feat(agents): capabilities` | Protocols/mixins + `McpBinding`/`SkillBinding`/`AgentRules` | **new**, stacks on 8 | 8 |
| 10 | `feat(chaos)` | typed `ChaosResult`/`Fault`/`Trigger`; loop reuse; **authoring contract** | **rework #7** | 5 · (#6 is a *soft* template only — parallel-OK) |
| 11 | `fix(metrics)` | PR #8 fix list + reviewer note (Phase 0) | **rework #8** | — |
| 12 | `feat(metrics): registry` | `METRICS` + `MetricScore` + `run_geval`; collapse orchestrator | **new**, stacks on 11 | 11 |
| 13 | `feat(verification): registry` | `VERIFIERS` + registry-driven spec parsing | **new** | 6 |
| **Stage 3 — harness** |
| 14 | `feat(harness): port` | orchestrator decomposition + §2 cleanups (registry-only resolution, single `BENCH_USE_MCP`, workspace_path, prompt accessor) | **rework #10** | 6, 8/9, 10, 12 |
| 15 | `feat(harness): scenario seams` | typed `ChaosResult`/`VerificationResult`; mapping lookup; `action.inject`/`trigger.wait`; **`optimize-scale/task.yaml` migration** (harness half of authoring UX, §4.6) | **new** | 6, 10, 14 |
| 16 | `feat(harness): agent config` | build `AgentConfig`+capabilities; record `capabilities_granted`; `agent.run→AgentResult` | **new** | 9, 14 |
| 17 | `feat(harness): typed seams + reporter` | `run(list[Task])` typed in/out; thread `use_mcp` into `MetricContext`; extract `ResultReporter` | **new** | 12, 14 |

**Count: 17 PRs** — 4 open, 1 stacked-on-#92, 6 reworks, 6 new.

**Bundling flexibility (if fewer PRs are preferred):**

- **`models/loop.py` folded into #92 (D1 preferred):** drop #5 → **−1**.
- **Combine #11 + #12 into one `feat(metrics)` PR — recommended.** They share the
  `_record_metrics` → `run_geval` consolidation (#11 fix #3 *becomes* #12's `run_geval`), so
  combining avoids doing it twice. Split only if you want the low-risk #8 fix list to merge
  early, independently of the registry design. **−1**.
- **Combine #13 into #6 — optional.** Saves throwaway: go straight to registry-driven
  `VerificationSpec` parsing and never build the static `Annotated[Union, discriminator]`
  that #6 would otherwise create and #13 would replace. Keep separate if #6 must stay a
  tightly-scoped correctness fix and the registry trade-off (loss of native pydantic
  discrimination error text) is reviewed on its own. **−1**.
- **Collapse all of Stage 3 into one `feat(harness)` PR — this is D4 option (b), the cleaner
  path.** Land all Stage 2 components in typed form first, then write the harness **once,
  born consuming clean interfaces** — no behavior-preserving port (#14) + retrofit (#15–#17)
  churn. Requires every typed contract (`Task`/`AgentResult`/`ChaosResult`/
  `VerificationResult`/`MetricScore`) to exist first. Split later along the three seams —
  (a) scenario wiring + `task.yaml`, (b) agent config/capabilities, (c) typed `Task` in/out +
  `ResultReporter` — only if it gets too large. **−3**.
- **Applying all four → ~12 PRs** (4 open + `models/loop.py` + 1 verification(+registry) +
  3 agents + 1 chaos + 1 metrics + 1 harness).

**Hard ordering edges (everything else is parallelizable — notably #6 ∥ #10):**
`#92 → #5 → {#8, #10}` · `#6 → {#13, #15}` · `Stage 2 (typed) → #14` (or → the single Stage 3 PR).
