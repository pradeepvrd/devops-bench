# Shared Conventions Contract

**Audience:** every implementer landing a piece of the harness refactor
(verification, chaos, agents, metrics, harness).
**Status:** binding contract. The five `*-handoff.md` docs own *what* each component
does; this doc owns the cross-component idioms they must share so parallel work does
not diverge. Where a handoff disagrees with this doc, the
[`e2e-refactor-sequencing-plan.md`](e2e-refactor-sequencing-plan.md) is the reconciling
authority and is followed here.

Every snippet below matches the **real** Stage-1 foundation
(`fork/integration/devops-bench-stage1`): `core.Registry`, `core.Result`/`Status`,
`core.RunContext`, `models.base.LLMClient`/`get_model`, `tasks.schema.Task`,
`k8s.kubectl`/`k8s.conditions`. Do not invent APIs that contradict these.

---

## 1. Layering rules (e2e plan §2)

```
Layer 0  core/                     Registry, RunContext, ClusterInfo, Result/Status, errors, subprocess
            ▲
Layer 1  tasks/  deployers/(+providers)  k8s/  models/(+models/loop.py)
            ▲
Layer 2  verification/  chaos/  agents/  metrics/
            ▲
Layer 3  harness/                  orchestrator + reporter
```

Hard rules (enforced in review):

- **A higher layer may import a lower one; never the reverse.** Shared utilities sink
  to the lowest common layer — this is why `run_tool_loop` lives in `models/loop.py`
  (Layer 1), not in `agents/` or `chaos/`.
- **Layer-1 leaves import only `core`** (plus `providers`, for `deployers`). Leaves
  **must not import each other**.
- **Layer-2 components import Layer 1 + `core`, never each other.** `agents` and
  `chaos` are siblings: both depend on `models`, neither on the other. `chaos.verify`
  is an opaque string key — chaos never imports `verification`.
- **Layer 3 (`harness`) is the only place that wires components together**, and it does
  so by **consuming registries**, never by mirroring module paths.
- **`Task.chaos_spec` / `Task.verification_spec` stay opaque (`Any`) at Layer 1.** Each
  Stage-2 component parses the blob into its own typed nodes at its own boundary. Typing
  them with Stage-2 schemas would invert the layering — do not.

---

## 2. Registry idiom

`core.Registry[T]` is the one extension mechanism for **every** axis: METRICS,
VERIFIERS, FAULTS, TRIGGERS, AGENTS, MODELS, TASKS. Declare one module-level registry
per axis and self-register concretes with the decorator.

```python
# Declare (module-level, typed by what it holds — usually a class):
from devops_bench.core import Registry

FAULTS:    Registry[type["Fault"]]   = Registry("faults")
TRIGGERS:  Registry[type["Trigger"]] = Registry("triggers")
VERIFIERS: Registry[type]            = Registry("verifiers", entry_point_group="devops_bench.verifiers")
METRICS:   Registry[type["MetricEvaluator"]] = Registry("metrics", entry_point_group="devops_bench.metrics")

# Register (decorator returns the decorated object unchanged):
@FAULTS.register("generate_load")
class GenerateLoadFault(Fault):
    type: Literal["generate_load"]
    ...

# Consume:
cls = FAULTS.get("generate_load")        # NotRegisteredError lists known keys on a miss
for cls in METRICS.values(): ...         # iterate all registered
if "generate_load" in FAULTS: ...        # membership
```

Real API surface (from `core/registry.py` — use only these): `register(key)` decorator,
`get(key)`, `__getitem__`, `__contains__`, `__iter__`, `__len__`, `keys()`, `items()`,
`values()`, `.name`. `get`/membership/iteration trigger a **one-time** entry-point scan
when `entry_point_group` is set. Duplicate keys raise `AlreadyRegisteredError`; misses
raise `NotRegisteredError(registry, key, available)`.

**Registration ordering gotcha (do not rely on import side effects):** because
`__init__` stays light (§8), a concrete is only registered once its module is imported.
Trigger registration explicitly — import the builtin modules **at call time** in the
consumer, or wire `entry_point_group`. Documented per consumer; never assume the facade
imported it.

**Harness resolves via registry, never module paths.** Delete the `_AGENT_MODULES` /
`_AGENT_KEYS` path/alias tables; resolve through `AGENTS.get(key)` only (import builtins
once at call time or register them as entry points). Aliases (`cli`/`binary` → `gemini`)
move into the registry or are normalized to the canonical key in one place. Acceptance:
a dummy `@AGENTS.register("dummy")` resolves with **no harness edit**; likewise a dummy
`@METRICS.register("dummy")` appears in `res["scores"]` and a dummy
`@VERIFIERS.register("dummy_check")` parses, each with no central edit.

---

## 3. Typed-result idiom

Every component boundary returns a typed result, never a hand-rolled dict. **Two
families exist in the foundation — match the one your component already uses:**

- **`core.Result` is a `@dataclass`** with `Status` (a `StrEnum`), `reason`,
  `elapsed_sec`, `details`, `.ok`, classmethods `passed/failed/errored/skipped`, and
  `to_dict()`. Use it for generic step outcomes.
- **`VerificationResult` is a pydantic `BaseModel`** (it lives next to pydantic spec
  nodes). **`ChaosResult` is also pydantic** (mirrors verification — chaos
  handoff §5.4). **`AgentResult` / `ToolCall` are `@dataclass`es** (agents handoff §2).
  `MetricScore` is a `@dataclass` (metrics handoff §4.2).

Rule of thumb: a result that travels **with pydantic spec nodes** (verification, chaos)
is pydantic; a result built **imperatively by a runner/agent** (agents, metrics) is a
dataclass. Do not mix within a component.

Required shapes (authoritative — copy these field names):

```python
# agents/result.py  (dataclass)
@dataclass
class ToolCall:                        # canonical trajectory entry, EVERY agent emits this
    name: str
    args: dict
    result: str | None = None
    status: str = "called"             # "called" | "completed" | "error"

@dataclass
class AgentResult:
    output: str
    trajectory: list[dict]             # list of ToolCall.to_dict() (+ optional text turns)
    tokens: dict = field(default_factory=dict)
    latency: float = 0.0
    errors: list[str] = field(default_factory=list)
    metadata: dict = field(default_factory=dict)
    def to_dict(self) -> dict: ...
    @classmethod
    def errored(cls, msg: str, *, latency: float = 0.0) -> "AgentResult": ...

# chaos/base.py  (pydantic)
class ChaosResult(BaseModel):
    success: bool
    injected_fault: str                # fault id/name — keys diagnosis scoring in metrics
    output: str = ""
    elapsed_time: float = 0.0
    error: str | None = None

# verification/base.py  (pydantic) — drop the old loose `details`
class VerificationResult(BaseModel):
    success: bool
    elapsed_time: float
    reason: str
    name: str | None = None                              # echoed from the node label
    children: list["VerificationResult"] = Field(default_factory=list)  # compounds
    raw: dict | None = None                              # leaf kubectl diagnostics

# metrics/base.py  (dataclass)
@dataclass
class MetricScore:
    name: str
    score: float | None
    success: bool | None = None
    reason: str | None = None
    def to_entry(self) -> dict | float | None: ...
```

**`results.json` stability (Decision D3 — preserve the legacy shape).** Route every
on-disk write through a `to_entry()`/`to_dict()` so the existing schema does not drift:

- `MetricScore.to_entry()` returns the **bare value** (`self.score`) when both `success`
  and `reason` are None (rates / perf passthroughs), else `{"score","success","reason"}`.
- `AgentResult.to_dict()` is the boundary shim the harness consumes.
- Do **not** normalize the mixed shape now; that is a separate, reviewer-noted
  output-schema change (D5).

---

## 4. Discriminated-union node idiom

Spec nodes (chaos `Fault`/`Trigger`; verification leaves + `SequenceSpec`/`ParallelSpec`)
are **`type`-tagged pydantic `BaseModel`s** discriminated on the `type` literal.

**`name` is metadata, never structure.** A node carries an optional `name: str | None`
for result labeling only. The old "dict whose key is a `name` string alongside the spec"
anti-pattern is gone — that is exactly the bug that kept the real `optimize-scale` spec
from parsing. Recursion is explicit via a `checks: list[...]` field, not nesting bare
lists/dicts. **Bare lists/dicts as spec nodes are rejected**; authoring is
explicit-`type`-only.

```python
# verification/spec.py  (Phase-A: pydantic discriminated union)
class SequenceSpec(BaseModel):
    type: Literal["sequence"]; name: str | None = None; checks: list["VerificationNode"]
class ParallelSpec(BaseModel):
    type: Literal["parallel"]; name: str | None = None; checks: list["VerificationNode"]

VerificationNode = Annotated[
    PodHealthyVerifier | ScalingCompleteVerifier | SequenceSpec | ParallelSpec,
    Field(discriminator="type"),
]
class VerificationSpec(RootModel[VerificationNode]):
    """``VerificationSpec(data).root`` yields a concrete node."""

# chaos/spec.py  (same idiom, separate union)
ChaosAction  = Annotated[GenerateLoadFault, Field(discriminator="type")]   # grows w/ faults
ChaosTrigger = Annotated[TimeTrigger,       Field(discriminator="type")]   # grows w/ triggers
class ChaosSpec(BaseModel):
    name: str = "Planned Disruption"
    trigger: ChaosTrigger
    action: ChaosAction
    verify: str | None = None        # references a verification KEY (or inline node), never imports verification
```

- A **bare leaf is a valid whole spec** (it is a union member) — single checks need no
  wrapper. Use `RootModel` + `model_rebuild()` for the forward refs.
- **Native YAML, not JSON-in-YAML.** Task files author nodes as plain YAML mappings;
  the spec models validate at author time. Placeholder substitution still round-trips
  through a serialized string.

**Phase-A → Phase-4 swap (e2e plan §5 reconciliation).** Phase A ships the
**hand-maintained** `Annotated[Union, Field(discriminator="type")]` (matches pydantic's
native discriminator error text, byte-for-byte consistent across verification and
chaos). Phase 4 swaps **only the parsing** to be registry-driven: a
`model_validator(mode="before")` / `parse_node(data)` reads `data["type"]`, looks up
`VERIFIERS.get(type)`, validates against that model, and recurses on `checks` — dropping
the static union so a new verifier needs no central edit. The runner's
`isinstance(node, SequenceSpec/ParallelSpec)` dispatch is unchanged. (Resolution: the
chaos handoff's "open design point" of registry-vs-hand-maintained union is settled —
hand-maintained in Phase A, registry-driven in Phase 4.)

**Every component ships a regression test that a literal of the real `optimize-scale`
spec parses and discriminates correctly** (§9) — this is the gap that hid the original
bug.

---

## 5. Neutral message / tool-result contract (e2e plan §3.1)

`run_tool_loop` + the API agent + the chaos agent all depend on these **exact** dict
shapes. They are the de-facto behavior of all three `models` adapters today; treat them
as a frozen contract. **Quote verbatim:**

- **user turn:** `{"role": "user", "content": goal}`
- **assistant turn:**
  `{"role": "assistant", "content": text}`, plus `"tool_calls"` when the model called
  tools:
  ```python
  assistant_message = {"role": "assistant", "content": text}
  if function_calls:
      assistant_message["tool_calls"] = function_calls
  ```
- **tool result:**
  `{"role": "tool", "tool_call_id": id, "name": name, "content": result}`

A **function call** (an entry in `tool_calls`, as returned by
`LLMClient.extract_function_calls`) is `{"name": ..., "args": ..., "id": ...}` (`id` may
be `None`). `tool_call_id` on the tool-result entry echoes `call.get("id")`.

These keys are exactly what `models.base.LLMClient.generate_content(contents, tools,
system_instruction)` expects in `contents` and what the adapters' provider-format
conversion consumes — do not rename `role`/`content`/`tool_calls`/`tool_call_id`/`name`.

---

## 6. `run_tool_loop` contract (chaos handoff §5.1)

The single shared turn-loop primitive. Lives at **Layer 1** (`models/loop.py`), imports
only `models.base` + `core`. Both `agents/api/loop.py` and `chaos/agent.py` consume it;
neither carries its own loop.

```python
# devops_bench/models/loop.py
ToolDispatcher = Callable[[str, Any, str | None], Awaitable[str]]   # (name, args, call_id) -> result text

@dataclass
class LoopResult:
    response: Any                      # last raw provider response
    contents: list[dict]               # full conversation history (the §5 shapes)
    final_text: str                    # text retained on EVERY turn
    latency: float                     # total generate_content seconds
    tools_used: set[str] = field(default_factory=set)

async def run_tool_loop(
    client: LLMClient,
    goal: str,
    tools: Any,                        # pre-formatted; see locked decision below
    system_instruction: str | None,
    dispatch: ToolDispatcher,
    max_turns: int,
) -> LoopResult: ...
```

Behavior the primitive must preserve:

- Seed `contents=[{"role": "user", "content": goal}]`; per turn append the assistant
  message and one tool-result entry per call (the §5 shapes).
- **Retain `final_text = text` on every turn** so a tool call on the last turn / the
  turn cap never discards the model's summary.
- `for turn in range(max_turns): … else: warn("turn limit (%d)", max_turns)`.
- Accumulate `latency` from each `generate_content` call.

**Locked decision: the caller formats tools.** `run_tool_loop` receives **pre-formatted**
`tools` (the caller calls `client.format_tools(...)` first) and stays ignorant of
provider tool-descriptor shapes. Do not call `format_tools` inside the primitive.

The only things that differ between the two consumers are the `dispatch` closure (MCP +
skills vs. a local command handler) and how they build their result from `LoopResult`
(rich `AgentResult` vs. `ChaosResult` from `.final_text`). `agents/api/loop.py` must keep
its public `__all__` and emit byte-identical trajectory/tokens/latency after extraction.

---

## 7. Env-read rules

- **`BENCH_USE_MCP` is read once, by the harness, and threaded** — never re-read
  downstream. The harness reads it once and passes the resolved boolean into the scoring
  call / `MetricContext.use_mcp`. Agents and metrics **stop self-reading it**. (Full
  closure later: harness records `capabilities_granted` and metrics read that.) This
  kills the agent-vs-judge disagreement.
- **`get_model(provider, model_name)` takes explicit args** — callers own env
  precedence. Chaos selects via `first_env("CHAOS_PROVIDER","AGENT_PROVIDER")` /
  `("CHAOS_MODEL","AGENT_MODEL")`; agents via `AGENT_PROVIDER`/`AGENT_MODEL`. The model
  factory itself only falls back to `AGENT_PROVIDER` when `provider` is None.
- **No env-smuggling across seams.** Configuration flows as typed args
  (`AgentConfig`, `MetricContext`, `RunContext`), not via `os.environ` reads buried in a
  component. Capabilities/MCP-on-off are driven by `config`, not an in-agent env read.

---

## 8. Light `__init__` / lazy imports

`import devops_bench.<pkg>` must pull **no** provider SDK, `deepeval`, `mcp`, fortio
tooling, or concrete implementation. (Mirrors `models/__init__.py`, which exports only
`MODELS`, `LLMClient`, `get_model` and imports each adapter SDK only at construction.)

- `chaos/__init__.py` exports only `Fault`, `Trigger`, `ChaosResult`, `FAULTS`,
  `TRIGGERS`, `ChaosSpec`. It does **not** eager-import `ChaosAgent` or the concrete
  fault; concretes register lazily (call-time import or `entry_point_group`).
- `metrics/__init__.py` keeps a lazy `__getattr__` facade so importing the package does
  not pull `deepeval`; builtin metric modules are imported **at call time** inside
  `evaluate_metrics_batch`.
- Heavy imports (`deepeval`, `mcp`, provider SDKs) are function-local, never module-top.
- One-way import graph: e.g. `generate_load` → `agent` → `models`; no lazy back-edges to
  paper over a cycle.

---

## 9. Testing & lint bar

Every PR, independently (the tree is never left broken between stacked PRs):

- **`uv run ruff check` clean.**
- **`uv run pytest` green** — the full unit suite, plus the component's own tests.
- **Google-style docstrings** on public objects: one-line **purpose**, `Args:`/`Returns:`
  (`Attributes:` for dataclasses/models), and `Raises:` for exceptions. Concise; do not
  narrate the implementation.
- **`import devops_bench.<pkg>` pulls no SDK / `deepeval` / `mcp`** (§8) — assert in a
  test where practical.
- **Each component ships the real-spec regression test:** load a literal of the actual
  `complextasks/optimize-scale` spec for that component and assert it parses and
  discriminates to the expected concrete nodes —
  - verification → `VerificationSpec` validates and dispatches (leaf `verify` stubbed);
  - chaos → `ChaosSpec` discriminates to `GenerateLoadFault` / `TimeTrigger` with the
    expected `target.service_url` / `qps` / `delay_seconds`.
  This is the locked gap; do not ship the component without it.
- **Extension-axis tests:** a dummy `@METRICS.register("dummy")` shows up in
  `res["scores"]` with no orchestrator edit; a dummy `@VERIFIERS.register("dummy_check")`
  parses with no union edit; a dummy `@AGENTS.register("dummy")` resolves with no
  `_AGENT_MODULES` entry.
- **Timeouts on every external call** (subprocess / API turn); extraction failures land
  in `AgentResult.errors`, never silent-empty.

---

## Quick reference — names not to drift on

| Concept | Canonical name | Layer / file |
|---|---|---|
| Registry type | `core.Registry[T]`, `@REG.register("key")`, `REG.get("key")` | core |
| Generic step result | `core.Result` (dataclass) + `core.Status` (StrEnum) | core |
| Run state carrier | `core.RunContext` (`workspace_path`, `cluster`, `env`) | core |
| Model factory | `get_model(provider, model_name)` | models |
| k8s primitives | `kubectl.get_json(...)`, `kubectl.wait(...)`, `conditions.poll_until(...)` | k8s |
| Shared loop | `run_tool_loop(...) -> LoopResult`, `ToolDispatcher` | models/loop.py |
| Neutral msg keys | `role` / `content` / `tool_calls` / `tool_call_id` / `name` | §5 |
| Function call | `{"name", "args", "id"}` | §5 |
| Typed results | `AgentResult`/`ToolCall`, `ChaosResult`, `VerificationResult`, `MetricScore` | §3 |
| Spec nodes | `type`-tagged pydantic; `name` is metadata; `checks` for recursion | §4 |

> **k8s naming gotcha:** the foundation function is `kubectl.get_json(...)`, **not**
> `get_resource` (some handoffs say "get_resource"). Verifiers must null-guard
> `.status` on its return, since it is raw kubectl JSON.
