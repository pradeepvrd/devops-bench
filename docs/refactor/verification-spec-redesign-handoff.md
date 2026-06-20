# Handoff: Verification spec redesign (PR #6)

**Audience:** an implementing agent picking up PR #6
(`feat(verification): outcome verification engine`, branch
`feat/devops-bench-verification`).
**Status:** design approved; not yet implemented. No code has been changed.

---

## 1. Context — why this work exists

PR #6 restructured the legacy verifier into `devops_bench/verification/`. A review
of it surfaced structural problems that this handoff fixes:

- **The only real compound spec in the repo does not parse.**
  `complextasks/optimize-scale/task.yaml` defines a verification as a dict carrying a
  `name` string alongside `pod_spec`/`scaling_spec`. The schema arm is
  `dict[str, VerificationSpec]`, so the `name` *value* (a bare string) fails
  validation (verified: 7 pydantic errors). The harness swallows it via a broad
  `except Exception` and records a phantom "Verification exception." No test catches
  it because every test mocks the verifier or omits `name`.
- **The spec overloads bare `list`/`dict`.** Both mean "sequential AND," and the dict
  arm conflates structure with metadata. There is no way to say "these checks are
  independent — run them in parallel."
- **The timeout model is hard to reason about.** A relative budget is recomputed and
  threaded at every level with two different rules (sequence draws it down; the
  planned parallel reset it per member). You cannot look at a leaf and know its
  timeout. The runner uses `time.time()` (wall clock) while the `poll_until` it calls
  uses `time.monotonic()` — two clock sources.
- **`VerificationResult.details` is effectively `Any`**
  (`dict[str, VerificationResult] | list[VerificationResult] | dict | None`), and it
  overloads one field with two meanings (child results vs. raw kubectl output).
- **Authoring UX is poor:** specs are JSON embedded in YAML `|` blocks, referenced by
  a stringly-typed name into a separate registry list.

## 2. Goal

A verification spec that:
1. expresses **sequence** (ordered) vs. **parallel** (independent) execution explicitly;
2. has **one, easily-reasoned timeout model**;
3. is **pleasant to author** in native YAML and validates at author time;
4. is **type-safe end to end**, with the real `optimize-scale` spec parsing and a test
   that locks the regression.

## 3. Decisions already locked (do not re-litigate)

- Compounds are **first-class `type`-tagged nodes** (`sequence`, `parallel`),
  discriminated on `type` exactly like the leaves. Recursion is explicit via a
  `checks` list.
- **Sequences are fail-fast:** stop at the first failed step; record the rest as skipped.
- **Authoring is explicit-`type`-only:** bare lists/dicts as spec nodes are rejected.
- **Single absolute monotonic deadline** for the whole verification (see §6).
- **Out of scope (do not build):** a full DAG (`depends_on`), and an `any`/OR
  quantifier. Both compounds mean "all must pass." These slot in cleanly later; build
  them only when a task needs them.

---

## 4. Target schema

All nodes live in one discriminated union. Leaves gain an optional `name` (for result
labeling only — never structural).

`devops_bench/verification/spec.py`:

```python
from typing import Annotated, Literal
from pydantic import BaseModel, Field, RootModel
from devops_bench.verification.verifiers.pod_healthy import PodHealthyVerifier
from devops_bench.verification.verifiers.scaling_complete import ScalingCompleteVerifier

class SequenceSpec(BaseModel):
    """Ordered, fail-fast group: members run in sequence; stop at first failure."""
    type: Literal["sequence"]
    name: str | None = None
    checks: list["VerificationNode"]

class ParallelSpec(BaseModel):
    """Independent group: members run concurrently; all must pass."""
    type: Literal["parallel"]
    name: str | None = None
    checks: list["VerificationNode"]

# Leaves and compounds, side by side, keyed on ``type``.
VerificationNode = Annotated[
    PodHealthyVerifier | ScalingCompleteVerifier | SequenceSpec | ParallelSpec,
    Field(discriminator="type"),
]

class VerificationSpec(RootModel[VerificationNode]):
    """Entry-point wrapper so ``VerificationSpec(data).root`` yields a concrete node."""

SequenceSpec.model_rebuild()
ParallelSpec.model_rebuild()
VerificationSpec.model_rebuild()
```

- Add `name: str | None = None` to `PodHealthyVerifier` and `ScalingCompleteVerifier`.
- A **bare leaf is a valid whole spec** (it is in the union) — single checks need no wrapping.
- Export `SequenceSpec`, `ParallelSpec` from `verification/__init__.py`.

## 5. Target result model

`devops_bench/verification/base.py` — replace the loose `details` with typed fields:

```python
class VerificationResult(BaseModel):
    success: bool
    elapsed_time: float
    reason: str
    name: str | None = None                               # echoed from the node label
    children: list["VerificationResult"] = Field(default_factory=list)  # compound nodes
    raw: dict | None = None                               # leaf kubectl diagnostics

VerificationResult.model_rebuild()
```

The two leaf verifiers currently build `VerificationResult(details=...)`; change those
to `raw=...` (in `verifiers/pod_healthy.py` and `verifiers/scaling_complete.py`). Their
check logic is otherwise unchanged. Thread an optional `name` through if present.

Confirm nothing downstream reads `details`: `harness/scenario.py` only reads
`success` and `elapsed_time` off the result, so the reshape is safe.

## 6. Timeout model — single absolute deadline

Replace the relative draw-down budget with **one monotonic deadline computed once at
the top and compared everywhere**. Sequence consumes it serially; parallel
concurrently. This removes all per-node budget arithmetic, makes each leaf's timeout
knowable, bounds total wall-clock, and uses one clock source.

`devops_bench/verification/runner.py` — rewrite `VerifierAgent` (keep the class name
and the `wait_for_condition(spec, timeout_sec=120)` signature; many tests and
`scenario.py` depend on them). Delete the `_remaining` / `_timed_out_result` helpers
and the old list/dict branches.

```python
import time
from concurrent.futures import ThreadPoolExecutor, wait as futures_wait
from devops_bench.verification.spec import (
    VerificationSpec, SequenceSpec, ParallelSpec,
)
from devops_bench.verification.base import VerificationResult

_MAX_PARALLEL_WORKERS = 8

class VerifierAgent:
    def wait_for_condition(self, spec, timeout_sec: float = 120) -> VerificationResult:
        node = spec.root if isinstance(spec, VerificationSpec) else VerificationSpec(spec).root
        deadline = time.monotonic() + timeout_sec
        return self._run(node, deadline)

    def _run(self, node, deadline: float) -> VerificationResult:
        if isinstance(node, SequenceSpec):
            return self._run_sequence(node, deadline)
        if isinstance(node, ParallelSpec):
            return self._run_parallel(node, deadline)
        return self._run_leaf(node, deadline)

    def _run_leaf(self, node, deadline: float) -> VerificationResult:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return _timed_out(node, "deadline exhausted before evaluation")
        return node.verify(remaining)   # leaf.verify(timeout_sec) is unchanged

    def _run_sequence(self, node, deadline: float) -> VerificationResult:
        start = time.monotonic()
        children, reasons, ok = [], [], True
        for i, child in enumerate(node.checks):
            if time.monotonic() >= deadline:
                children.append(_skipped(child, "deadline exhausted"))
                reasons.append(f"[{i}] skipped"); ok = False
                continue
            res = self._run(child, deadline)
            children.append(res)
            if not res.success:
                ok = False
                reasons.append(f"[{i}] failed: {res.reason}")
                for j, rest in enumerate(node.checks[i + 1:], start=i + 1):
                    children.append(_skipped(rest, "earlier step failed"))
                    reasons.append(f"[{j}] skipped")
                break                      # fail-fast
            reasons.append(f"[{i}] succeeded")
        return VerificationResult(success=ok, elapsed_time=time.monotonic() - start,
                                  reason="; ".join(reasons), children=children, name=node.name)

    def _run_parallel(self, node, deadline: float) -> VerificationResult:
        start = time.monotonic()
        results: list[VerificationResult | None] = [None] * len(node.checks)
        with ThreadPoolExecutor(max_workers=min(_MAX_PARALLEL_WORKERS, len(node.checks))) as ex:
            futs = {ex.submit(self._run, child, deadline): i for i, child in enumerate(node.checks)}
            done, _ = futures_wait(futs, timeout=max(0.0, deadline - time.monotonic()))
            for f, i in futs.items():
                results[i] = f.result() if f in done else _timed_out(node.checks[i], "deadline reached")
        ok = all(r.success for r in results)
        reasons = [f"[{i}] {'ok' if r.success else 'fail'}" for i, r in enumerate(results)]
        return VerificationResult(success=ok, elapsed_time=time.monotonic() - start,
                                  reason="; ".join(reasons), children=results, name=node.name)
```

`_timed_out` / `_skipped` are small module helpers returning a failed
`VerificationResult` with `name=getattr(node, "name", None)` and `elapsed_time=0.0`.

**Invariant to preserve:** the whole verification races a single deadline. If a per-node
`timeout` override is ever added, it may only *tighten* the inherited deadline
(`effective = min(inherited, now + node.timeout)`) — never extend it. Do **not** add
this override now; it is the documented extension point.

Note in a code comment that a parallel child still blocked in `kubectl wait`/`poll_until`
when the deadline hits is bounded by the `remaining` it was handed, so threads do not
linger long past the deadline.

---

## 7. Authoring UX (task files)

### 7a. Native YAML, no JSON-in-YAML

`harness/default.py::_process_spec` (≈ lines 217-220) already accepts a native
dict/list (`json.dumps` → `replace_placeholders` → `json.loads`), so task files can
drop the `|` JSON blob and write specs as native YAML. Keep placeholder substitution
working (it runs on the serialized string; the round-trip preserves it).

### 7b. Registry as a mapping; inline-or-reference

Make the verification registry a **mapping whose key is the name** (kills the `name`
double-duty and the stringly cross-reference), and let a chaos entry either reference a
key or inline a node.

Migrate `complextasks/optimize-scale/task.yaml` from:

```yaml
verification_spec: |
  [ { "name": "Planned Load Spike Verification",
      "pod_spec": {...}, "scaling_spec": {...} } ]
```

to native YAML with a tagged `parallel` node:

```yaml
verifications:                      # registry: the KEY is the name
  planned_load_spike:
    type: parallel
    checks:
      - { type: pod_healthy,      selector: "app={{TARGET_DEPLOYMENT_NAME}}", namespace: "{{NAMESPACE}}" }
      - { type: scaling_complete, deployment: "{{TARGET_DEPLOYMENT_NAME}}", min_replicas: 2, namespace: "{{NAMESPACE}}" }

chaos:
  - name: Planned Load Spike
    trigger: { type: time, delay_seconds: 5 }
    action:  { type: generate_load, target: { service_url: "http://{{TARGET_DEPLOYMENT_NAME}}.{{NAMESPACE}}.svc.cluster.local", qps: 300 } }
    verify: planned_load_spike      # reference by key… or inline a node directly under `verify:`
```

### 7c. Harness wiring

- `harness/scenario.py::run_chaos_and_verification`: today it reads
  `spec.get("verification")`; if a string it looks up a *list* by `name`, if a dict it
  inlines. Change the lookup to a **mapping** (`registry.get(ref)`); the inline-dict
  path stays. Pass the resolved node straight to `wait_for_condition` — no `name`
  stripping needed, since the node is `type`-tagged.
- `harness/default.py` (≈ lines 196-199, 208): the verification field now resolves to a
  mapping, not a list. Update the variable that was `verification_spec_list:
  list[dict]` to carry the mapping and thread it to `ScenarioManager`.
- `tasks/schema.py`: `chaos_spec` / `verification_spec` are typed `Any`; no change
  required, but consider renaming the field to `verifications` for clarity if you touch it.

> The field/key renames in 7b-7c are the only cross-cutting churn. If you want to land
> the engine first, you can keep the existing list-registry and just migrate the node
> *shape* (§4-§6 + the `task.yaml` node body) — the real spec will then parse. Do 7b/7c
> as an immediate follow-up so the UX win lands too.

### 7d. Ship a JSON Schema (optional but recommended)

The models are pydantic, so `VerificationSpec.model_json_schema()` is free. Emit it to
`docs/` (or a `schemas/` dir) and/or add a `validate-task` command so authors get
editor autocomplete/validation and discover the available `type`s and fields.

---

## 8. File-by-file change list

| File | Change |
|---|---|
| `verification/spec.py` | Discriminated union + `SequenceSpec`/`ParallelSpec`; forward refs + `model_rebuild()`. Drop the `RootModel[dict\|list\|Single]` union. |
| `verification/base.py` | `VerificationResult`: drop `details`; add `name`, `children`, `raw`. Add `name` to `BaseVerifier`. |
| `verification/runner.py` | Deadline-based `VerifierAgent` (§6); delete `_remaining`/`_timed_out_result` and the list/dict branches. |
| `verification/verifiers/pod_healthy.py` | `details=` → `raw=`; pass `name` through. Add `name` field. |
| `verification/verifiers/scaling_complete.py` | Same as above. |
| `verification/__init__.py`, `verifiers/__init__.py` | Export new node types. |
| `complextasks/optimize-scale/task.yaml` | Migrate to native-YAML tagged `parallel` node (§7b). |
| `harness/scenario.py` | Mapping-based registry lookup; pass resolved node to `wait_for_condition`. |
| `harness/default.py` | Verification field resolves to a mapping; thread it through. |
| tests | See §9. |

## 9. Tests (`tests/unit/verification/`, `tests/unit/harness/`)

Rewrite `test_verification_runner.py` for the new model and add coverage:

- **parallel** runs concurrently and ANDs (one child fails → node fails);
- each parallel child sees ~the full remaining deadline (assert the `timeout_sec`
  passed into a stubbed `verify`);
- **sequence fail-fast**: after the first failed child, later children are *skipped*
  (their `verify` is never called) and recorded as skipped;
- **nested** (sequence ⊃ parallel) dispatches both levels and aggregates;
- **deadline**: with a patched `time.monotonic`, a sequence past the deadline skips the
  rest; a leaf past the deadline returns timed-out without calling `verify`.
- Drop the old list/dict-keyed and `_remaining` tests.

Leaf tests: update assertions from `details` to `raw`.

**Regression test (required):** load the migrated `optimize-scale` verification node
(or an equivalent literal) through `VerificationSpec`, assert it validates, and dispatch
it with both leaf `verify` methods stubbed — this is the gap that hid the original bug.

`test_harness_scenario.py` mocks `VerifierAgent`; update any literal spec args to the
tagged shape and the registry lookup to a mapping.

## 10. Verification / acceptance

- `ruff check` clean; `pytest tests/unit/verification tests/unit/harness` green.
- Parse-and-dispatch the migrated `optimize-scale` spec end-to-end (verifier `verify`
  stubbed): success aggregates correctly; a parallel node's children each receive the
  full remaining deadline; a sequence stops on first failure.
- Grep shows no remaining references to `VerificationResult.details`, `_remaining`, or
  bare list/dict spec arms.

**Done when:** the real `optimize-scale` task spec parses and runs, sequence/parallel
are expressible and tested, the timeout model is the single-deadline abstraction, and
the suite is green.
