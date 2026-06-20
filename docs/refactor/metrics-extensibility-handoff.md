# Handoff: Metrics & verification extensibility (PR #8 + follow-ups)

**Audience:** an implementing agent landing PR #8
(`feat(metrics): LLM-as-judge metrics pipeline (Stage 2d)`, branch
`feat/devops-bench-metrics`) and the metric/verifier registry follow-ups.
**Status:** PR #8 fix list is ready to apply; the registry designs are approved at
the design level, not yet implemented.

---

## 1. Context — why this work exists

PR #8 extracts the LLM-as-judge scoring out of the legacy monolith
`pkg/evaluator/evaluate.py` into a modular `devops_bench/metrics/` package
(Stage 2d of `docs/migration`). The extraction is clean and well-tested, but a
review surfaced three things this handoff addresses:

1. **A small set of correctness/clarity fixes** worth landing on PR #8.
2. **Real scoring semantic changes vs. the monolith** that reviewers must be told
   about so they can reason about score deltas.
3. **The extensibility gap:** adding a metric still means editing a 200-line
   orchestrator (`evaluate_metrics_batch`), and adding a verifier still means
   editing a central pydantic `Union`. The team wants this closed as new tasks and
   verification methodologies are added.

The codebase already has the right tool for (3): `devops_bench/core/registry.py`
provides a generic `Registry[T]` with entry-point plugin discovery, and it is
**already wired into agents and tasks** (`AGENTS`, `TASKS`). The high-leverage
move is to apply that same self-registration pattern to the two axes it was *not*
applied to — **metrics** and **verifiers** — so the whole codebase has one
consistent "drop in a module, decorate it, done" extension story.

> Note on the orphan skill file: `skills/outcome-validity-skill.md` is a
> superseded 1–5-scale variant of `outcome-validity-checklist.md`, referenced by
> no code (not even legacy `pkg/evaluator/evaluate.py`, which only ever opened the
> `-checklist` and `tool-invocation` files). PR #8 correctly ported the two live
> files and dropped it. It is **intentionally left in place** for now; no action
> required.

---

## 2. PR #8 fix list (small, mergeable on the PR now)

File references are on branch `feat/devops-bench-metrics`.

| # | Fix | File | Behavior impact |
|---|---|---|---|
| 1 | Add `CHECKLIST_THRESHOLD = 0.8`; stop reusing `TOOL_INVOCATION_THRESHOLD` as the checklist pass cutoff. | `metrics/pipeline.py` | None (value-preserving); removes a misleading coupling. |
| 2 | Delete dead grounding branches: `total_constraints == 0`, the `recall_accuracy … else 1.0`, and the `non_critical_total == 0 → 5.0` arms. All unreachable because the function returns early at `if not doc_metrics: return`. | `metrics/grounding.py` | None (dead code inherited from legacy). |
| 3 | Promote `pipeline._record_metrics` to one shared recorder and reuse it; `grounding.py` and `chaos_metrics.py` each re-inline the same `" [GEval]"`-strip + `scores[name] = {...}` loop (3 copies). | `metrics/pipeline.py`, `grounding.py`, `chaos_metrics.py` | None; becomes `run_geval()` in §4. |
| 4 | Decide `extract_checklist_items` visibility — it is in `pipeline.__all__` but not the package facade. Either export it from `metrics/__init__.py` (it is unit-tested) or rename to `_extract_checklist_items`. | `metrics/__init__.py`, `pipeline.py` | None. |
| 5 | Fix the stale PR description: it references `docs/migration/pr-plan.md` (not on this branch) and says skills load from "repo-root `skills/`" — they actually ship as `devops_bench.skills` package data via `importlib.resources`. | PR body | Docs only. |
| 6 | *(Optional, perf)* Batch DeepEval: each metric is currently its own `evaluate([case], metrics=[m])` round-trip. Batching metrics that share a test-case shape into one `evaluate([case], metrics=[…])` call cuts judge round-trips. Also flagged in `docs/master_review_report.md`. | `metrics/pipeline.py` | Behavior-neutral if the result→score mapping is preserved — verify. |
| 7 | Add the §3 reviewer note to the PR body. | PR body | Docs only. |

---

## 3. Reviewer note — scoring semantic changes vs. legacy (copy-paste into the PR)

> **Scoring semantics changed by this refactor.** The metrics package is *not* a
> byte-for-byte port of `pkg/evaluator/evaluate.py`. The diffs below were verified
> against both sources; most are intended fixes. Anything consuming `results.json`
> directly should review them.
>
> - **GroundingAccuracy / ParameterRecallAccuracy — constraint dedup (real change).**
>   Legacy appended one GEval per constraint *occurrence*, so a constraint shared
>   by two guides was double-counted in `total_constraints` while `applied` was
>   deduped — making a perfect 5.0 unreachable and inflating the recall
>   denominator. This refactor builds metrics from the deduped
>   `doc_constraints_map`, so `total == unique`. For any task with overlapping
>   constraint texts, both scores change (generally corrected upward). **Intended
>   fix.**
> - **`OutcomeValidity` / `ToolInvocation` key names (output-schema change).**
>   Legacy wrote these two keys *with* the ` [GEval]` suffix (the outcome/tool
>   paths did not strip). This refactor strips uniformly, so the keys become
>   `OutcomeValidity` / `ToolInvocation`, now consistent with the
>   dynamic/doc/chaos keys (which legacy already stripped). Anything parsing
>   `results.json` keyed on the suffixed names must update. The bundled `site/`
>   and `site_new/` dashboards run on **mock data** and are unaffected.
> - **DocRetrievalRate robustness.** Legacy used direct
>   `doc["doc_name"]`/`doc["url"]` access (KeyError on missing keys) and did not
>   truthiness-guard `doc_name` (an empty name matched every step → spurious 1.0).
>   This refactor uses `.get(…) or ""` and guards both. Differs only for
>   malformed/missing-key documentation entries (now robust).
> - **Checklist item text — trailing-hyphen fix.** Legacy `line.strip("- ")`
>   stripped trailing hyphens/spaces too, corrupting items like `…staging-`; this
>   refactor uses `line.lstrip("- ").strip()`. Changes the `Check: {item}` metric
>   name/criteria for affected items.
> - **Judge loop-awareness (behavioral, not scoring).** `ModelLayerJudge.generate`
>   no longer crashes when called inside a running event loop (legacy used a naive
>   `asyncio.run`). Affects whether scoring completes in async contexts, not the
>   values.
> - **Provider-agnostic judge construction.** The judge is built via the models
>   layer (`get_model`, `JUDGE_PROVIDER` / `JUDGE_MODEL`) instead of inline
>   provider SDKs. Same providers, different construction path.
>
> **Explicit non-changes** (to prevent confusion): the ChecklistScore pass cutoff
> is still 0.8; the `total_constraints == 0` grounding branch was already dead in
> legacy (same early return).

---

## 4. Metrics registry + typed result (extensibility design)

### 4.1 Problem

`metrics/pipeline.py::evaluate_metrics_batch` hardcodes the orchestration —
`if use_mcp`, `if dynamic_metrics`, `if documentation`, `if res.get("chaos_spec")`
— so adding a metric means surgery on the orchestrator. Score entries are also
stringly-typed and inconsistent: most are `{"score","success","reason"}` dicts,
but `DocRetrievalRate`, `ParameterRecallAccuracy`, and the chaos perf numbers are
written as bare floats, so every consumer must defensively type-check.

### 4.2 Design — reuse `devops_bench.core.Registry`, mirroring `AGENTS` / `TASKS`

New module **`devops_bench/metrics/base.py`**:

```python
from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from typing import Any, Protocol, runtime_checkable

from deepeval.test_case import LLMTestCase

from devops_bench.core import Registry

METRICS: Registry[type["MetricEvaluator"]] = Registry(
    "metrics", entry_point_group="devops_bench.metrics"
)


@dataclass
class MetricScore:
    """One score entry produced by a metric evaluator.

    Attributes:
        name: Score key written into ``res["scores"]``.
        score: Numeric score, or None for metrics that only report success.
        success: Pass/fail flag; None for bare-value metrics (rates/perf).
        reason: Human-readable explanation, when the metric produced one.
    """

    name: str
    score: float | None
    success: bool | None = None
    reason: str | None = None

    def to_entry(self) -> dict[str, Any] | float | None:
        """Serialize in the legacy ``results.json`` shape.

        Judged metrics emit a ``{"score","success","reason"}`` dict; bare-value
        metrics (DocRetrievalRate / ParameterRecallAccuracy / perf) emit the raw
        value so the on-disk schema is unchanged. See §6 for the normalization
        decision that would replace this.
        """
        if self.success is None and self.reason is None:
            return self.score
        return {"score": self.score, "success": self.success, "reason": self.reason}


@dataclass
class MetricContext:
    """Everything a metric needs to score one execution result.

    The three test cases are built once per result and shared, so individual
    metrics never rebuild them.
    """

    result: dict[str, Any]
    judge: Any
    use_mcp: bool
    outcome_case: LLMTestCase
    tool_case: LLMTestCase
    all_case: LLMTestCase


@runtime_checkable
class MetricEvaluator(Protocol):
    """A self-registering metric family."""

    name: str

    def applies(self, ctx: MetricContext) -> bool:
        """Whether this metric runs for the given result."""

    def evaluate(self, ctx: MetricContext) -> Iterable[MetricScore]:
        """Produce zero or more score entries for the result."""


def run_geval(case: LLMTestCase, metrics: list[Any]) -> list[MetricScore]:
    """Evaluate GEval metrics against ``case`` and return clean MetricScores.

    This is the single shared recorder: it strips DeepEval's trailing
    ``" [GEval]"`` suffix once, replacing the three duplicated copies in
    pipeline/grounding/chaos.
    """
    from deepeval import evaluate

    out: list[MetricScore] = []
    result = evaluate([case], metrics=metrics)
    for test_result in result.test_results:
        for md in test_result.metrics_data:
            name = md.name[:-8] if md.name.endswith(" [GEval]") else md.name
            out.append(
                MetricScore(
                    name=name,
                    score=md.score,
                    success=md.success,
                    reason=getattr(md, "reason", None),
                )
            )
    return out
```

Each existing family becomes a small registered class wrapping its current builder
or evaluator function (the builders in `outcome_validity.py` / `tool_invocation.py`
stay; the grounding/chaos functions are adapted to yield `MetricScore`s):

```python
@METRICS.register("outcome_validity")
class OutcomeValidityMetric:
    name = "OutcomeValidity"

    def applies(self, ctx: MetricContext) -> bool:
        return True

    def evaluate(self, ctx: MetricContext) -> Iterable[MetricScore]:
        return run_geval(ctx.outcome_case, [build_outcome_validity_metric(ctx.judge)])


@METRICS.register("tool_invocation")
class ToolInvocationMetric:
    name = "ToolInvocation"

    def applies(self, ctx: MetricContext) -> bool:
        return ctx.use_mcp

    def evaluate(self, ctx: MetricContext) -> Iterable[MetricScore]:
        return run_geval(ctx.tool_case, [build_tool_invocation_metric(ctx.judge)])
```

The remaining families register the same way:

- `@METRICS.register("checklist")` — builds the dynamic per-item `Check: …` GEvals
  from `extract_checklist_items(...)`, yields each per-item score plus the
  aggregate `ChecklistScore` (using `CHECKLIST_THRESHOLD` from fix #1).
  `applies` → `bool(checklist_items)`.
- `@METRICS.register("grounding")` — `applies = bool(result.get("documentation"))`;
  yields the per-constraint scores, `GroundingAccuracy`, `ParameterRecallAccuracy`,
  and `DocRetrievalRate`.
- `@METRICS.register("chaos")` — `applies = bool(result.get("chaos_spec"))`;
  yields `DiagnosisAccuracy`, `GracefulRecovery`, and the perf passthroughs.

### 4.3 The orchestrator collapses

```python
def evaluate_metrics_batch(detailed_results, judge_model) -> None:
    use_mcp = get_bool("BENCH_USE_MCP", True)
    evaluators = [cls() for cls in METRICS.values()]
    for res in detailed_results:
        ctx = _build_context(res, judge_model, use_mcp)   # builds the 3 test cases
        scores: dict[str, Any] = {}
        for ev in evaluators:
            if not ev.applies(ctx):
                continue
            try:
                for ms in ev.evaluate(ctx):
                    scores[ms.name] = ms.to_entry()
            except Exception:  # noqa: BLE001 - one metric must not abort the rest
                _log.exception("metric %r failed for %s", ev.name, res.get("name"))
        res["scores"] = scores
```

Adding a metric = a new `@METRICS.register(...)` class in a metric module.
**Zero edits to the orchestrator.** External packages can register metrics through
the `devops_bench.metrics` entry-point group for free.

### 4.4 Registration / import ordering (gotcha)

Builtin metric modules must be imported for their `@METRICS.register` decorators
to run, but the package keeps the lazy `__getattr__` facade so importing
`devops_bench.metrics` does not eagerly pull in `deepeval`. Resolve this by having
`pipeline` import the builtin metric modules at call time (inside
`evaluate_metrics_batch`, not at module top), or by listing the builtins as
internal entry points. Document whichever you pick; do not rely on import side
effects from the facade.

---

## 5. Verifier registry (extends `verification-spec-redesign-handoff.md`)

`docs/refactor/verification-spec-redesign-handoff.md` already moves verification to
first-class `type`-tagged nodes (`SequenceSpec` / `ParallelSpec`) with a single
monotonic deadline. **Read and land that first** — it is the prerequisite. But it
keeps a hand-edited discriminated union:

```python
VerificationNode = Annotated[
    PodHealthyVerifier | ScalingCompleteVerifier | SequenceSpec | ParallelSpec,
    Field(discriminator="type"),
]
```

so every new check still edits that union. This section adds the missing
self-registration dimension.

### 5.1 Design

- `VERIFIERS: Registry[type] = Registry("verifiers",
  entry_point_group="devops_bench.verifiers")`, with every leaf and compound
  registered by its `type` literal:
  `@VERIFIERS.register("pod_healthy")`, `"scaling_complete"`, `"sequence"`,
  `"parallel"`.
- **Recommended:** make `VerificationSpec` registry-driven. Replace the static
  `Annotated[Union, discriminator]` with a `RootModel` whose
  `model_validator(mode="before")` (or a standalone `parse_node(data)` function)
  reads `data["type"]`, looks up `VERIFIERS.get(type)`, and validates the dict
  against that model. Compounds recurse through the same parser for their `checks`.
  - True self-registration: new verifier = subclass `BaseVerifier` +
    `type: Literal["x"]` + `@VERIFIERS.register("x")`, no central edit.
  - Unknown `type` yields a `NotRegisteredError` listing the known keys (better
    than a generic union error).
  - Trade-off: gives up pydantic's *automatic* discriminated-union error text;
    acceptable for the extensibility win.
- **Alternative (noted, not recommended):** build the
  `Annotated[Union[…], Field(discriminator="type")]` dynamically from
  `tuple(VERIFIERS.values())` after all registrations, then `model_rebuild()`.
  Keeps native discrimination but is import-order-fragile.
- The runner is unchanged: `VerifierAgent._run` still dispatches on
  `isinstance(node, SequenceSpec / ParallelSpec)`. **Only spec parsing becomes
  registry-driven.**

### 5.2 Result

One consistent self-registration story across agents, tasks, metrics, and
verifiers. Adding a task's verification method *and* its metric is two small
self-registering modules — no central-file surgery anywhere.

---

## 6. Sequencing, flagged decisions, acceptance

### Sequencing

- **Phase 0 (now):** PR #8 fix list (§2) + reviewer note (§3). Lands the clean
  extraction.
- **Phase 1:** verification-spec redesign (the existing handoff). Prerequisite for
  a clean verifier registry.
- **Phase 2:** metrics registry + `MetricScore` + shared `run_geval` (§4). Builds
  on the PR #8 module decomposition.
- **Phase 3:** verifier registry (§5). Builds on Phase 1.

### Flagged decisions (do not silently choose)

- **Score-entry normalization.** `MetricScore.to_entry()` preserves the legacy
  mixed shape (dict vs. bare float) by default. Normalizing *all* entries to one
  dict shape is cleaner for consumers but is an output-schema change → needs a
  reviewer note and any direct `results.json` consumers updated. Decide
  explicitly; default is preserve.
- **Reporter abstraction.** Output is still a hardcoded `json.dump`. The
  `ResultReporter` ABC sketched in `docs/interfaces.md` would let output sinks
  (DB, dashboard) be added without editing the harness. Out of scope here; noted
  as the natural next extension axis.

### Acceptance

- `ruff check` clean; `pytest tests/unit/metrics` green (the suite mocks
  `deepeval`, which stays an optional dev dependency).
- **Metrics:** a new test registering a dummy `@METRICS.register("dummy")` metric
  and asserting it appears in `res["scores"]` with **no edit to
  `evaluate_metrics_batch`**.
- **Verification:** the `optimize-scale` parse-and-dispatch regression test from
  the verification handoff, plus a test registering a dummy
  `@VERIFIERS.register("dummy_check")` leaf and parsing a spec that uses it
  **without editing any union**.
- Grep shows the ` [GEval]`-strip lives in exactly one place (`run_geval`).

---

## 7. File-by-file change list

| File | Phase | Change |
|---|---|---|
| `metrics/pipeline.py` | 0 | `CHECKLIST_THRESHOLD`; reuse shared recorder; decide `extract_checklist_items` export; (opt) batch DeepEval. |
| `metrics/grounding.py` | 0 | Delete dead branches; use shared recorder. |
| `metrics/chaos_metrics.py` | 0 | Use shared recorder. |
| PR #8 body | 0 | Reviewer note (§3); fix stale references. |
| `metrics/base.py` | 2 | New: `MetricScore`, `MetricContext`, `MetricEvaluator`, `METRICS`, `run_geval`. |
| `metrics/{outcome_validity,tool_invocation,grounding,chaos_metrics}.py` | 2 | Add registered `MetricEvaluator` classes wrapping existing builders. |
| `metrics/pipeline.py` | 2 | Collapse `evaluate_metrics_batch` to the registry loop; import builtins at call time. |
| `verification/spec.py` | 3 | Registry-driven parsing (`VERIFIERS` + validator); drop the static union. |
| `verification/verifiers/*.py` | 3 | Add `@VERIFIERS.register(...)` to each leaf/compound. |
| `tests/unit/metrics`, `tests/unit/verification` | 2,3 | Dummy-registration tests (§6). |
