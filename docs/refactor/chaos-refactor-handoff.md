# Handoff: Chaos package refactor (PR #7)

**Audience:** an implementing agent picking up the chaos refactor for PR #7
(`feat(chaos): chaos injector with Trigger/Fault registries (Stage 2c)`, branch
`feat/devops-bench-chaos`).
**Status:** design approved; **not yet implemented — do not start code changes until
told.** No code has been changed.
**Sibling template:** this mirrors `docs/verification-spec-redesign-handoff.md` (the
verifier redesign). Read that first — chaos must end up structurally consistent with
`verification/`.

---

## 1. Context — why this work exists

PR #7 moved the legacy chaos injector (`pkg/agents/chaos/chaos.py`) into
`devops_bench/chaos/`. The move is a genuine improvement (model-agnostic via
`devops_bench.models`, shell-free argv execution, real bug fixes, good tests). But judged
against the migration plan (`docs/migration/`) and the verifier redesign, it has
structural problems this refactor fixes:

- **ChaosAgent forks its own LLM turn-loop** (`chaos/agent.py:235-276`) that re-implements
  the canonical loop in `agents/api/loop.py` (`_run_agent_loop` / `process_query`,
  `loop.py:183-381`): same `contents` shape, assistant-message build, tool-result shape,
  turn-cap, and `format_tools/generate_content/get_text_content/extract_function_calls`
  sequence. Two loops to maintain; the chaos one is the *uncanonical* model-agnostic driver.
- **Bare dicts where a concrete model belongs.** `Fault.inject(spec: dict, context:
  dict | None) -> dict` and `Trigger.is_triggered(state: dict)` use untyped dicts; the
  sibling `verification/` returns a typed `VerificationResult` (`verification/base.py:26`)
  and parses `type`-tagged Pydantic nodes. The design doc even names a `ChaosResult`
  (`docs/migration/component-design.md §4`).
- **The chaos ABCs diverge from the documented target interface.** Design §4 specifies
  `Trigger.wait(ctx: RunContext) -> None` (blocking) and `Fault.inject(ctx: RunContext)
  -> ChaosResult`. PR #7 ships a polling `is_triggered`/`initialize` and a dict-based
  `inject`. `RunContext` already exists (`core/context.py`).
- **`agent.py` ↔ `faults/generate_load.py` is circular**, papered over with 3 lazy imports
  (`agent.py:217-221`, `generate_load.py:563-565,601-606`), because the "generic" agent
  holds fortio-specific content (`SYSTEM_INSTRUCTION`, `RUN_COMMAND_TOOL`,
  `build_system_instruction`, `target_url_from_spec`).
- **`chaos/__init__.py` eager-imports concretes** (the agent + the concrete fault),
  violating migration principle #8; `models/__init__` and `agents/__init__` keep `__init__`
  light and load concretes lazily.
- **The real consumer bypasses the interface.** `harness/scenario.py` calls `ChaosAgent`
  directly (`scenario.py:25,69`) and re-implements goal-building + the action-type check
  (`_inject_fault`, `222-247`) instead of `FAULTS.get(type).inject(...)`. The two
  goal-builders (`scenario.py:239-246` vs `generate_load.py:568-578`) have already drifted.
- **Authoring UX is poor:** `complextasks/optimize-scale/task.yaml` defines `chaos_spec` as
  JSON embedded in a YAML `|` block, with `verification` a stringly cross-reference — the
  exact anti-pattern the verifier handoff (§7) fixes.

## 2. Goal

A chaos package that:
1. drives a **single, canonical model-agnostic loop** shared with `agents/api/`;
2. is **type-safe end to end** — typed `ChaosResult`, `type`-tagged Pydantic `Fault`/
   `Trigger` nodes in a discriminated union, no bare dicts;
3. has a **clean one-way import graph** (no circular lazy imports; light `__init__`);
4. is **authored in native YAML** and validates at author time, with its real task spec
   parsing under a regression test;
5. is **structurally consistent with `verification/`** (same patterns, mirrored file layout).

## 3. Decisions already locked (do not re-litigate)

- **Loop dedup = extract + refactor both.** Add a generic model-agnostic loop primitive in
  `devops_bench/models/` (layer 2) and refactor **both** `chaos/agent.py` and
  `agents/api/loop.py` onto it. Chaos may **not** import the `agents/` sibling (migration
  §1.7 / §5 forbid sibling imports); a `models/` home is the design-legal way to share
  ("shared utilities sink to a lower layer").
- **Event signal = `RunContext` + explicit typed arg.** Carry `chaos_active_event` as an
  explicit `threading.Event | None` parameter alongside `RunContext`. **Do not** modify
  core `RunContext` — the design's `EventStream` is deferred (`pr-plan.md §3`).
- **`Fault`/`Trigger` become `type`-tagged Pydantic nodes** (like `BaseVerifier`), parsed
  via a discriminated union (like `VerificationSpec`). Keep the `FAULTS`/`TRIGGERS`
  registries for the design-mandated extension axes (principle #4).
- **Migrate the consumer in the same effort:** `harness/scenario.py` drives faults through
  `fault.inject(...)`, not an inline goal-builder.
- **Out of scope (do not build):** new fault/trigger types beyond `generate_load` /
  `time`; the design's `EventStream`; entry-point `pyproject.toml` wiring beyond what
  `providers/` already demonstrates (use it only if it's the cleanest lazy-registration
  path).

## 4. Patterns adopted from the verifier handoff

| Verifier handoff | Chaos equivalent |
|---|---|
| `VerificationResult` typed; dropped loose `details: …\|Any` (§5) | `ChaosResult` typed model |
| `BaseVerifier(BaseModel, ABC)` with `type` literal + `verify()` (§4) | `Fault`/`Trigger` as `type`-tagged `BaseModel` + `inject()`/`wait()` |
| `VerificationSpec` discriminated union, bare list/dict rejected (§4) | `chaos/spec.py`: `ChaosAction`/`ChaosTrigger` unions + `ChaosSpec` |
| Native YAML; registry as name-keyed mapping; inline-or-reference (§7) | task.yaml native-YAML chaos node; `verify:` references a verification key |
| Keep public signature OR migrate consumers (§6) | migrate `scenario.py` onto `fault.inject(...)` |
| Regression test parses the real task spec (§9) | parse the real `optimize-scale` chaos entry through `ChaosSpec` |

---

## 5. Target design

### 5.1 Shared loop primitive — `devops_bench/models/loop.py` (new)

The only thing that differs between the API agent and the chaos agent is **tool dispatch**
(MCP+skills vs. a local command handler) and the **result shape** (rich dict vs. final
text). Extract everything else:

```python
# devops_bench/models/loop.py  (layer 2: imports only models.base + core)
from __future__ import annotations
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any
from devops_bench.models.base import LLMClient

# dispatch(name, args, call_id) -> tool result text
ToolDispatcher = Callable[[str, Any, str | None], Awaitable[str]]

@dataclass
class LoopResult:
    response: Any                      # last raw provider response
    contents: list[dict]               # full conversation history
    final_text: str                    # text retained on EVERY turn (see below)
    latency: float                     # total generate_content seconds
    tools_used: set[str] = field(default_factory=set)

async def run_tool_loop(
    client: LLMClient,
    goal: str,
    tools: Any,                        # formatted via client.format_tools by the CALLER
    system_instruction: str | None,
    dispatch: ToolDispatcher,
    max_turns: int,
) -> LoopResult:
    """Drive client through a tool-use loop until it stops calling tools or the cap hits."""
```

Behavior to preserve from the current loops:
- Build `contents=[{"role": "user", "content": goal}]`; each turn append the assistant
  message (`{"role":"assistant","content":text[, "tool_calls":calls]}`) and, per tool call,
  a `{"role":"tool","tool_call_id":id,"name":name,"content":result}` entry.
- **Retain `final_text = text` on every turn** (the bug fix already in `chaos/agent.py:257`)
  so a tool call on the last turn / turn cap does not discard the model's summary.
- `for turn in range(max_turns): … else: _log.warning("…turn limit (%d)", max_turns)`.
- Accumulate `latency` from each `generate_content` call (as `loop.py:process_query` does).

> Decide whether `run_tool_loop` calls `client.format_tools` internally or expects
> pre-formatted tools. Recommended: caller formats (matches both current loops, keeps the
> primitive ignorant of tool descriptor shapes).

### 5.2 Refactor `agents/api/loop.py` onto the primitive

- Reimplement `_run_agent_loop` (`loop.py:325-381`) to build an MCP+skills `dispatch`
  closure and call `run_tool_loop`, then build the rich result (`_build_result`,
  `_build_trajectory`, tokens/latency) from `LoopResult.contents` / `.response` / `.latency`.
- **Preserve the public API** in `__all__` (`ApiAgent`, `run_api_agent`, `process_query`,
  `call_mcp_tool`, `parse_skill_md`) — `tests/unit/agents/…` depend on it. Keep
  `process_query` as a thin per-turn helper (or reimplement it over the primitive's
  internals) so its tests still pass. Trajectory/token/latency output must be unchanged.
- The DeepEval `@observe` wrappers stay where they are (`run_api_agent`, `call_mcp_tool`);
  the primitive itself is tracing-agnostic.

### 5.3 `chaos/agent.py` — reuse the primitive, shed fortio specifics

- `ChaosAgent.run(goal)` builds a local `dispatch` that wraps the fault command handler
  (`run_chaos_command`) and the `chaos_active_event`, calls `run_tool_loop`, and returns
  `LoopResult.final_text`. Keep `_MAX_TURNS = 8`, the `client`/`tool_handler` DI seams, and
  `first_env("CHAOS_PROVIDER","AGENT_PROVIDER")` / `("CHAOS_MODEL","AGENT_MODEL")` selection.
- **Move fortio-specific content out of `agent.py` into `faults/generate_load.py`:**
  `SYSTEM_INSTRUCTION` (`agent.py:150`), `build_system_instruction` (`83-122`),
  `RUN_COMMAND_TOOL` (`154-170`), `target_url_from_spec` (`125-145`). After this, `agent.py`
  has no fortio strings and **no lazy imports** — the dependency is one-way
  (`generate_load` → `agent` → `models`). `agent.py` keeps only `ChaosAgent` and `_MAX_TURNS`.

### 5.4 Typed nodes + result — `chaos/base.py` and `chaos/spec.py`

`chaos/base.py` (mirror `verification/base.py`):

```python
from abc import ABC, abstractmethod
import threading
from pydantic import BaseModel
from devops_bench.core import Registry
from devops_bench.core.context import RunContext

class ChaosResult(BaseModel):
    """Structured outcome of a chaos fault injection."""
    success: bool
    injected_fault: str            # fault id/name — keys diagnosis scoring in metrics
    output: str = ""               # the model's final summary text
    elapsed_time: float = 0.0
    error: str | None = None

class Fault(BaseModel, ABC):
    """A type-tagged disruption node that injects itself. Carries its own params."""
    # concrete subclasses add: type: Literal["generate_load"], target: LoadTarget, …
    @abstractmethod
    def inject(self, ctx: RunContext,
               chaos_active_event: threading.Event | None = None) -> ChaosResult: ...

class Trigger(BaseModel, ABC):
    """A type-tagged firing condition."""
    @abstractmethod
    def wait(self, ctx: RunContext) -> None: ...   # blocks until the condition is met

FAULTS: Registry[type[Fault]] = Registry("faults")
TRIGGERS: Registry[type[Trigger]] = Registry("triggers")
```

`chaos/spec.py` (new, mirror `verification/spec.py`):

```python
from typing import Annotated, Literal
from pydantic import BaseModel, Field
from devops_bench.chaos.faults.generate_load import GenerateLoadFault
from devops_bench.chaos.triggers.time_delay import TimeTrigger   # see note below

ChaosAction  = Annotated[GenerateLoadFault, Field(discriminator="type")]   # union grows w/ faults
ChaosTrigger = Annotated[TimeTrigger,       Field(discriminator="type")]   # union grows w/ triggers

class ChaosSpec(BaseModel):
    """One chaos entry: a trigger, an action, and a verification ref-or-inline node."""
    name: str = "Planned Disruption"
    trigger: ChaosTrigger
    action: ChaosAction
    verify: str | None = None        # references a verification key (Phase B) or inline node
```

- `GenerateLoadFault(Fault)`: `type: Literal["generate_load"]`, `target: LoadTarget`
  (`service_url: str`, `qps: int`, `duration: str | None`, `concurrency: int | None`),
  `inject(...) -> ChaosResult`. It owns the fortio specifics moved in §5.3 and the
  `run_chaos_command` argv executor (keep `_LOAD_MARKER = "fortio load"`,
  `_COMMAND_TIMEOUT = 40`, `~` expansion). Drop `get_agnostic_spec` — the model *is* the
  agnostic spec (`model_dump()`).
- `TimeTrigger(Trigger)`: `type: Literal["time"]`, `delay_seconds: int = 0`,
  `wait(ctx)` sleeps `delay_seconds`. (Currently the delay lives inline in
  `scenario.py:163-166`; this is the typed home for it.) Place under a new
  `chaos/triggers/` dir, mirroring `chaos/faults/`.
- Keep `@FAULTS.register("generate_load")` / `@TRIGGERS.register("time")` self-registration.

> **Open design point (flag, don't silently choose):** the discriminated union lists
> concrete classes explicitly (as `verification/spec.py` does), *and* there are registries.
> Decide whether the union is hand-maintained (simplest, matches verification) or assembled
> from the registries. Recommended: hand-maintained union + registries for discovery, to
> stay byte-for-byte consistent with the verifier pattern.

### 5.5 Slim `chaos/__init__.py`

Export only `Fault`, `Trigger`, `ChaosResult`, `FAULTS`, `TRIGGERS` (+ `ChaosSpec` from
`spec`). **Do not** eager-import `ChaosAgent` or the concrete fault. Register concrete
faults/triggers lazily — either give `FAULTS`/`TRIGGERS` an `entry_point_group` (see
`providers/base.py:29`) or import the concrete modules on demand. Goal: `import
devops_bench.chaos` pulls no provider SDK and no concrete implementation.

---

## 6. Phasing

**Phase A — type-safety + canonical-loop reuse (the locked directives).** §5.1–§5.5 plus
the Phase-A tests. Lands without touching task files.

**Phase B — authoring UX (verifier handoff §7; immediate follow-up).**
- Migrate `complextasks/optimize-scale/task.yaml` `chaos_spec` from JSON-in-YAML to native
  YAML `type`-tagged nodes; `verify:` references the verification key. Target shape
  (from verifier handoff §7b):
  ```yaml
  chaos:
    - name: Planned Load Spike
      trigger: { type: time, delay_seconds: 5 }
      action:  { type: generate_load, target: { service_url: "http://{{TARGET_DEPLOYMENT_NAME}}.{{NAMESPACE}}.svc.cluster.local", qps: 300 } }
      verify: planned_load_spike
  ```
- `harness/scenario.py`: parse the typed `ChaosSpec`; rewrite the action's
  `target.service_url` to the local port-forward via **typed field assignment**; honor the
  trigger via `trigger.wait(ctx)`; **drive the fault via `action.inject(ctx,
  chaos_active_event)`** — delete the inline goal-builder (`239-246`) and the duplicate
  type-check (`231-233`). Build `chaos_report` from the returned `ChaosResult`
  (`injected_fault`, `success`/`status`, `error`). Keep the public
  `run_chaos_and_verification(...)` and `get_reports()` signatures (tests + `default.py`
  depend on them).
- `harness/default.py` / `tasks/schema.py`: thread the parsed `ChaosSpec`; the `chaos_spec`
  `Any` field may be typed/renamed for clarity (optional).

> As in the verifier handoff §7 note, Phase A can land first; do Phase B as the immediate
> follow-up so the UX win lands too.

---

## 7. File-by-file change list

| File | Change | Phase |
|---|---|---|
| `devops_bench/models/loop.py` | **new** — `run_tool_loop` + `LoopResult` (§5.1) | A |
| `devops_bench/agents/api/loop.py` | `_run_agent_loop` → `run_tool_loop`; public API + tests preserved (§5.2) | A |
| `devops_bench/chaos/agent.py` | `ChaosAgent` → `run_tool_loop`; remove fortio specifics + lazy imports (§5.3) | A |
| `devops_bench/chaos/base.py` | `Fault`/`Trigger` as `type`-tagged `BaseModel`; add `ChaosResult` (§5.4) | A |
| `devops_bench/chaos/spec.py` | **new** — `ChaosAction`/`ChaosTrigger` unions + `ChaosSpec` (§5.4) | A |
| `devops_bench/chaos/faults/generate_load.py` | owns fortio specifics; `GenerateLoadFault`/`LoadTarget`; `inject -> ChaosResult`; drop `get_agnostic_spec` (§5.3-5.4) | A |
| `devops_bench/chaos/triggers/time_delay.py` (+ `triggers/__init__.py`) | **new** — `TimeTrigger.wait()` (§5.4) | A |
| `devops_bench/chaos/__init__.py` | slim; lazy/entry-point registration (§5.5) | A |
| `complextasks/optimize-scale/task.yaml` | native-YAML tagged chaos node (§6) | B |
| `devops_bench/harness/scenario.py` | typed `ChaosSpec`; `trigger.wait` + `action.inject`; `ChaosResult` → report; delete inline goal/type-check | B |
| `devops_bench/harness/default.py`, `devops_bench/tasks/schema.py` | thread typed `ChaosSpec` | B |
| `tests/unit/...` | see §8 | A/B |

## 8. Tests

`tests/unit/chaos/`, `tests/unit/agents/`, `tests/unit/harness/`.

- **Regression (required):** load the real `complextasks/optimize-scale` chaos entry
  through `ChaosSpec`; assert it validates and discriminates to `GenerateLoadFault` /
  `TimeTrigger` with the expected `target.service_url` / `qps` / `delay_seconds`. This is
  the gap that hid the verifier bug — lock it for chaos too.
- `fault.inject(...)` returns a `ChaosResult` (update existing `test_chaos_generate_load.py`
  assertions from the `{status,output}` dict to the model). Keep the LLM client + `run`
  mocked so no SDK/fortio executes.
- `ChaosAgent` tests retarget the shared primitive but keep coverage for: turn-cap +
  final-text retention, non-dict arg guard, empty-command guard, event-after-parse ordering,
  unknown-tool error.
- `agents/api/` loop tests must stay green after §5.2 (trajectory/tokens/latency unchanged).
- (Phase B) `test_harness_scenario.py`: update literal action args to the typed shape and
  the path to `action.inject` / `trigger.wait`; mock `ChaosAgent` / `fault.inject`.

## 9. Verification / acceptance

- `ruff check` clean; `pytest tests/unit/chaos tests/unit/agents tests/unit/harness` green;
  full suite green (PR claims 374 unit tests).
- The real `optimize-scale` chaos entry parses through `ChaosSpec` and dispatches to the
  concrete fault/trigger (LLM + `run` stubbed).
- Grep shows: no bare-dict `Fault.inject`/`context` and no `get_agnostic_spec`; no
  duplicated turn-loop or fortio constants left in `chaos/agent.py`; no lazy
  agent↔fault imports; `chaos/__init__.py` imports no concrete fault/agent.
- `agents/api/` behavior (trajectory/tokens/latency) byte-identical to before the loop
  extraction.

**Done when:** ChaosAgent runs on the shared model-agnostic loop, the chaos spec is typed
`type`-tagged Pydantic end to end (no bare dicts), the import graph is one-way with a light
`__init__`, the real task spec parses under a regression test, `scenario.py` drives faults
through the interface, and the suite is green.
