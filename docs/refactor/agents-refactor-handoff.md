# Handoff: Agent Harness Refactor — 3 Stacked PRs

> **Audience:** an implementing agent (or engineer) producing the stacked PRs below.
> **Scope of this doc:** the `devops_bench/agents/` package only. The orchestrator
> (`harness/default.py`) and metrics (`metrics/pipeline.py`) changes are **out of
> scope** here and ship as a separate follow-up (see §6).

## 0. How to use this doc

1. Read these first, in order:
   - `docs/migration/component-design.md` §2 (Transport vs Capabilities; "Capability Negotiation") and §7 (Skills) — *on the `docs/migration-plan` branch.*
   - `docs/migration/pr-plan.md` — the existing stacked-PR conventions (draft status, peer review, retargeting to `gke-labs/main`).
   - `docs/openclaw/sessions.md` — **authoritative** OpenClaw session/trajectory CLI surface. The OpenClaw extraction design in §5.2 is derived from it.
2. The three PRs (§3–§5) are **stacked**: PR2 branches off PR1, PR3 off PR2. Each must leave the tree green (ruff + unit tests) and be independently reviewable.
3. Honor the invariants in §7 on every PR.

## 1. Why we're doing this

The current agent package (open PRs #5, #9) is well-written line-by-line but the
abstraction is wrong in specific, fixable ways. Findings the design below resolves:

- **`AgentHarness` is too thin and too leaky.** It is just `run(prompt, context) -> dict`.
  Configuration, model, system instructions, and MCP/tools are smuggled through
  process env vars and hardcoded constants instead of being part of the interface.
- **`run_cli_agent` is a redundant second dispatch layer.** It re-routes by
  substring-matching the binary path (`"gemini" in target` / `elif "oc" in target` /
  generic stdin) even though the `AGENTS` registry already chose the class. Its
  openclaw-delegation and generic-stdin branches are effectively dead in production,
  and it makes `gemini.py` import from `openclaw.py` (backwards coupling).
- **OpenClaw-over-SSH is a test-specific assumption that leaked into the agent.**
  OpenClaw should run as a local `oc` binary, symmetric with Gemini. SSH/remote
  execution is a deployment concern, not part of the agent abstraction.
- **The result is an untyped dict, hand-rolled 8+ times, and not actually
  standardized** — `tools`/`skills` are agent-specific (OpenClaw always empty),
  `tokens` shape differs across agents, and the `trajectory` schema differs between
  CLI (`{name,args,status}`) and API (`{type,content,...}`) agents.
- **`tools`/`skills` are not results.** `skills` is never read by any metric;
  `tools` is redundant with the trajectory. Both are derivations, not raw outputs.
- **`BENCH_USE_MCP` regression vs `main`.** On `main` one env read drives both the
  agent and the scorer. In the restructured code the Gemini CLI agent is pinned to
  `bench_use_mcp=True` (never reads the env) while metrics still read it — they can
  disagree, silently breaking the "without tools" arm.
- **`system_instruction` is misnamed.** Its content is an operator brief
  ("you are a DevOps engineer… you MUST use your tools…") delivered three different
  ways (API system param, Gemini prompt-append, OpenClaw not at all). It is really
  **startup context** (GEMINI.md / AGENTS.md / CLAUDE.md), modeled as **Rules**.
- **Trajectory extraction reverse-engineers undocumented internal files.** Each CLI
  exposes an official structured channel that hands you the trajectory directly.

### Owner decisions already locked (do not relitigate)

- `GEMINI_MODEL` **is** a valid env var → keep the env overlay for Gemini model
  selection. Do **not** switch to `-m`.
- `--allowed-tools` is sufficient for now (ignore its deprecation).
- `-e none` does not disable extensions; use **`-e=""`** (empty) to disable.
- OpenClaw SSH transport is wrong coupling → **remove** it; local-only.
- `context` on `run()` is dead/grab-bag → **drop** it; system instructions become
  **Rules** (see §5.3). The name is **`AgentRules`** + capability **`SupportsRules`**
  (chosen over "StartupContext": names the intent, not the delivery mechanism; has
  precedent in Cursor/Windsurf "Rules"; reads naturally as run-scoped + arm-aware).

## 2. Target architecture (end state after all 3 PRs)

Three orthogonal axes for capabilities (the core mental model):

| Axis | Question | Modeled as | Owned by |
|---|---|---|---|
| **A. Contract** | Can this agent do MCP/skills/rules at all? | `@runtime_checkable` Protocol + mixin | agent (structurally) + task (requires) |
| **B. Binding** | *Which* MCP / *which* skills / *what* rules text? | plain data (`McpBinding`, `SkillBinding`, `AgentRules`) | **benchmark/environment** (orthogonal) |
| **C. Arm** | Is the binding granted *this run*? (with/without tools) | a resolved, **recorded** value (`capabilities_granted`) | orchestrator (the experiment) |

Key rule: **the binding is data, not a Protocol.** There is one `SupportsMcp`
contract whose attribute is `mcp_servers: list[McpBinding]`; "GKE" is a *value* in a
binding, never a type and never a string literal inside agent code.

Core types (final shape):

```python
# agents/result.py
@dataclass
class ToolCall:                      # canonical trajectory entry, emitted by EVERY agent
    name: str
    args: dict
    result: str | None = None        # tool output text, when known
    status: str = "called"           # "called" | "completed" | "error"

@dataclass
class AgentResult:
    output: str
    trajectory: list[dict]           # list of ToolCall.to_dict() (+ optional text turns)
    tokens: dict = field(default_factory=dict)
    latency: float = 0.0
    errors: list[str] = field(default_factory=list)   # surfaces extraction failures, etc.
    metadata: dict = field(default_factory=dict)       # agent-specific extras (e.g. raw stats)
    def to_dict(self) -> dict: ...   # boundary shim consumed by the orchestrator
    @classmethod
    def errored(cls, msg: str, *, latency: float = 0.0) -> "AgentResult": ...

# agents/config.py
@dataclass
class AgentConfig:
    model: str | None = None
    provider: str | None = None
    api_key: str | None = None
    timeout_sec: float | None = 600.0
    capabilities: "AgentCapabilities" = field(default_factory=lambda: AgentCapabilities())  # added in PR3
    @classmethod
    def from_env(cls) -> "AgentConfig": ...   # AGENT_MODEL/PROVIDER/API_KEY/TIMEOUT (+capabilities in PR3)

# agents/base.py
class AgentHarness(ABC):
    def __init__(self, config: AgentConfig | None = None) -> None:
        self.config = config or AgentConfig()
    def run(self, prompt: str) -> AgentResult:
        """Template method: owns deepeval tracing + latency + a broad safety net.
        Catches unexpected exceptions from _execute and converts to AgentResult.errored
        so one agent crash never aborts the benchmark."""
        ...
    @abstractmethod
    def _execute(self, prompt: str) -> AgentResult:
        """Build argv / drive the loop, run, parse, return a result. Owns its own
        known-error handling (subprocess/API)."""
```

`base.run()` removes the per-function `@observe()` closure, the `start_time`/`latency`
bookkeeping, and the hand-rolled dict from every implementation. Each `_execute`
returns an `AgentResult`; `base.run()` stamps `latency` and wraps tracing.

## 3. PR 1 — `agents/` base + `agents/cli/` (reworks open PR #5)

**Branch:** `feat/devops-bench-agents` (the existing PR #5 branch). **Base:** unchanged
from PR #5 (the fork integration base; retarget later per `pr-plan.md`).

### Files

- `agents/base.py` — `AgentHarness` (template `run` → abstract `_execute`), `AGENTS` registry. (`AgentConfig`/`AgentResult` imported from siblings.)
- `agents/config.py` *(new)* — `AgentConfig` + `from_env()` (model/provider/api_key/timeout). **No `system_instruction` field.** `capabilities` field is added in PR3.
- `agents/result.py` *(new)* — `AgentResult`, `ToolCall`, `to_dict()`, `errored()`.
- `agents/cli/gemini.py` — rewrite (target ~200 lines, from 363).
- `agents/cli/openclaw.py` — rewrite (target ~160 lines, from 357).
- `tests/unit/agents/` — `test_agents_base.py`, `test_agents_config.py`, `test_agents_result.py`, `test_agents_cli_gemini.py`, `test_agents_cli_openclaw.py`.

### Gemini agent (`cli/gemini.py`)

- **Delete** `run_cli_agent`, the `from devops_bench.agents.cli.openclaw import ...`,
  the substring dispatch, the `_run()`/`@observe` closure, and all latency/error
  boilerplate. `GeminiCliAgent._execute` builds argv directly.
- **argv:** `gemini -o stream-json --skip-trust` + (`--allowed-tools <t>` per tool in
  `config` allowed-tools — interim simple list in PR1, see note) **or** `-e=""` when
  there are no allowed tools, then `-p <prompt>`.
- **Model:** keep `_gemini_env()` mapping `AGENT_MODEL → GEMINI_MODEL`,
  `AGENT_API_KEY → GOOGLE_API_KEY/GEMINI_API_KEY`, OTEL disables (sourced from `config`).
- **Timeout:** pass `timeout=config.timeout_sec` to `core.subprocess.run`.
- **Trajectory: switch to `--output-format stream-json`** (see §5.1). Parse the event
  stream from stdout — no `~/.gemini/tmp/...` disk reads, no session-id glob, no
  internal-schema parsing. One parser replaces both `parse_gemini_cli_output` and
  `extract_trajectory_from_session`.
- Emit the **canonical trajectory** (`ToolCall` list). Put any Gemini-native stats in
  `AgentResult.metadata`, not as top-level fields. **Do not** emit `tools`/`skills`.

> **PR1 interim for allowed tools:** read the tool allow-list from
> `AGENT_ALLOWED_TOOLS` (comma-separated) via `AgentConfig`, defaulting to empty.
> This removes the hardcoded `_ALLOWED_MCP_TOOLS` GKE list from agent code now; PR3
> migrates this field into `McpBinding.tools` supplied by the orchestrator catalog.

### OpenClaw agent (`cli/openclaw.py`)

- **Remove the SSH transport entirely:** delete `run_openclaw_agent` (SSH), the
  `OPENCLAW_SSH_USER/VM_HOST/SSH_KEY` env, and `OPENCLAW_LOCAL`. `OpenClawAgent`
  always runs `oc` locally (the former `run_openclaw_agent_local` path).
- Keep: bash invocation for nvm sourcing (`shell=True`, `executable="/bin/bash"`,
  every interpolated value `shlex.quote`d), `_strip_ansi`, the pre-run session wipe,
  and `oc models set <id>` from `config` (keep `oc models set` unless you can confirm
  a per-turn `--model` flag on the installed `oc`; if so, prefer the flag — no global
  config mutation).
- **Timeout:** pass it to the subprocess.
- **Trajectory: replace the `sessionFile=` debug-log scrape** with the official
  session export (see §5.2). Emit the **canonical trajectory** (`ToolCall` list).

### Tests (PR1)

- `base`: abstract instantiation fails; `run()` populates `latency`; safety net turns a
  raising `_execute` into `AgentResult.errored`.
- `config`: `from_env()` mapping.
- `result`: `to_dict()` / `errored()` / `ToolCall` round-trip.
- `gemini`: stream-json parsing (tool_use/tool_result/result → canonical trajectory +
  tokens + output); `-e=""` when no tools; `--allowed-tools` per tool when present;
  model env overlay; timeout passed; subprocess/OS error → `errored`.
- `openclaw`: local invocation (`shell=True`, bash), `shlex` quoting, model-set
  fragment, trajectory export parsing, error → `errored`.
- **Remove** the now-deleted-behavior tests: `run_cli_agent` dispatch/delegation,
  oc-substring, generic-stdin; all SSH tests + `_SSH_ENV` + `OPENCLAW_LOCAL`.

### PR1 acceptance

- [ ] `GeminiCliAgent`/`OpenClawAgent` are the only dispatch; no `run_cli_agent`, no
      cross-module import, no SSH, no hardcoded GKE tool list in code.
- [ ] Both agents return a typed `AgentResult` with the canonical trajectory.
- [ ] Trajectory comes from the official channels (stream-json / `sessions export-trajectory`).
- [ ] Timeouts on every subprocess call. ruff clean. Tests green.

## 4. PR 2 — `agents/api/` (reworks open PR #9)

**Branch:** `feat/devops-bench-agents-api` (existing PR #9 branch), **stacked on PR1.**

### Scope

- Refactor `ApiAgent` / `loop.py` / `mcp.py` onto the new `AgentHarness` template
  method, `AgentConfig`, and `AgentResult`. Keep the model-agnostic `LLMClient`/
  `get_model` separation (good as-is), the lazy `mcp`/`deepeval` imports, and the
  `AGENT_MAX_TURNS` safety cap.
- **Emit the canonical trajectory.** Normalize the current typed turns
  (`user_input`/`agent_response`/`tool_output`) into `ToolCall` entries (text turns
  may be kept as separate entries but tool calls must match the canonical shape).
- **Remove `_SKILLS_DIR = "third_party/gke-mcp/skills"`.** The skills directory/list
  comes from `config` (interim field in PR2; becomes a `SkillBinding` in PR3).
- **Decouple skills from MCP.** Skill discovery must not live inside the
  `if bench_use_mcp` branch; gate it on its own (skills) input.
- **Drop `context["system_instruction"]`.** No replacement string field — Rules arrives
  in PR3. (Interim: API agent runs with no operator brief, matching the other agents.)
- **Stop self-reading `BENCH_USE_MCP`.** MCP on/off is driven by `config` (presence of
  an MCP server command / tools), not an env var read inside the agent. This is the
  agent-side half of closing the regression; the recorded single-source-of-truth lands
  in the orchestrator PR (§6).
- The MCP server command stays injected data (`AGENT_TARGET`/`MCP_SERVER_PATH` →
  `config`). `MCPClient` is already generic — keep it.
- Do **not** emit `tools`/`skills` as result fields (metadata only, if anything).

### Tests (PR2)

- Update `test_agents_api_loop.py` / `test_agents_api_mcp.py` to the new base/result;
  assert canonical trajectory; assert skills discovery is independent of MCP; assert no
  `BENCH_USE_MCP` read inside the agent; MCP-off path runs with no tools.

### PR2 acceptance

- [ ] `ApiAgent` uses the shared base/config/result and emits the canonical trajectory.
- [ ] No `_SKILLS_DIR` constant; skills and MCP are independently controlled by config.
- [ ] No `context` grab-bag; no `BENCH_USE_MCP` read in the agent. ruff clean. Tests green.

## 5. PR 3 — `agents/capabilities/` (new)

**Branch:** `feat/devops-bench-agents-capabilities`, **stacked on PR2.**

This PR introduces the capability *vocabulary* and makes each agent *consume*
bindings. The *resolution* (task × arm), the **GKE catalog**, arm-aware Rules text,
and the `capabilities_granted` recording live in the **orchestrator PR** (§6) — keep
that boundary crisp: PR3 ships Protocols + mixins + binding types + agent wiring;
it does **not** add task-schema fields, the GKE catalog, or negotiation.

### Files

- `agents/capabilities/__init__.py`
- `agents/capabilities/mcp.py` — `@runtime_checkable SupportsMcp` + `McpMixin`; `McpBinding`.
- `agents/capabilities/skills.py` — `SupportsSkills` + `SkillsMixin`; `SkillBinding` (dir/list); skill discovery/parsing helpers moved here from `api/loop.py`.
- `agents/capabilities/rules.py` — `SupportsRules` + `RulesMixin`; `AgentRules` (the operator brief text).
- `agents/config.py` — add `capabilities: AgentCapabilities` (an aggregate of the bindings); `from_env` populates interim bindings from the PR1/PR2 interim fields, which are then removed.

### Types

```python
@dataclass(frozen=True)
class McpBinding:
    name: str                      # "gke" is a value supplied by the orchestrator catalog
    command: tuple[str, ...] = ()  # how the API agent launches it; CLI agents may ignore
    tools: tuple[str, ...] = ()    # tools to expose / pre-approve

@dataclass(frozen=True)
class SkillBinding:
    paths: tuple[str, ...] = ()    # skill dirs/files to load (no hardcoded gke-mcp path)

@dataclass(frozen=True)
class AgentRules:
    text: str = ""                 # the operator brief; resolved arm-aware by the orchestrator

@dataclass(frozen=True)
class AgentCapabilities:
    mcp_servers: tuple[McpBinding, ...] = ()
    skills: SkillBinding = SkillBinding()
    rules: AgentRules = AgentRules()
    @property
    def allowed_tools(self) -> tuple[str, ...]:
        return tuple(t for s in self.mcp_servers for t in s.tools)
    @property
    def tools_enabled(self) -> bool:
        return bool(self.mcp_servers)
```

### Wiring each agent (consume, don't define)

- **Gemini** (`McpMixin`, `RulesMixin`): `--allowed-tools` from `capabilities.allowed_tools`;
  `-e=""` when none; deliver `rules.text` by writing the CLI's native context file
  (`GEMINI.md`) into the run working directory before invocation (the CLI auto-loads it).
- **OpenClaw** (`RulesMixin`, + skills/mcp as supported): deliver `rules.text` via the
  native `AGENTS.md` convention in the workspace. Declare only the capabilities `oc`
  actually supports (verify against the build).
- **API agent** (`McpMixin`, `SkillsMixin`, `RulesMixin`): launch
  `capabilities.mcp_servers`; load `capabilities.skills.paths`; deliver `rules.text`
  via the provider `system` parameter (the API transport's equivalent of a context file).

### §5.1 Gemini trajectory extraction (stream-json)

Use `--output-format stream-json`. It streams newline-delimited JSON events on stdout:

| event | carries |
|---|---|
| `init` | session id, model |
| `message` | user/assistant chunks |
| `tool_use` | tool call **name + arguments** |
| `tool_result` | tool **output** |
| `error` | non-fatal warnings (skip) |
| `result` | final text + aggregated **per-model token usage** |

Parser: read stdout line-by-line, JSON-decode each; map `tool_use` → `ToolCall(name,
args, status="called")`, fold the matching `tool_result` into `result`/`status`,
take final `output` + `tokens` from `result`. No disk access. **Verify exact field
names against the installed binary** (`gemini -o stream-json -p 'hi' | head`), since
event schemas vary by version; on a parse miss, record it in `AgentResult.errors`
rather than silently returning empty.

### §5.2 OpenClaw trajectory extraction (per `docs/openclaw/sessions.md`)

The benchmark runs `oc agent --local …` and **wipes the agent's sessions dir before
each run**, so exactly one fresh session exists afterward. Extract via the official
session commands — **not** the debug-log `sessionFile=` scrape, and **not**
`sessions tail` (it redacts tool args and result bodies as `{...redacted...}`):

1. Locate the session: `openclaw sessions --agent <name> --json` → take the single
   row's `key` (e.g. `agent:<name>:…`). For `--local` (no Gateway) runs, the store is
   the disk file `~/.openclaw/agents/<name>/sessions/sessions.json`; use `--store <path>`
   if agent discovery doesn't surface it.
2. Export the bundle: `openclaw sessions export-trajectory --session-key <key>
   --workspace <tmpdir> --json` (writes under `<tmpdir>/.openclaw/trajectory-exports/`).
3. Parse the exported trajectory JSONL (tool calls with name+args and tool results) →
   canonical `ToolCall` list; pull tokens/output from the bundle.

Trajectory sidecars are first-class JSONL files referenced by
`<session>.trajectory-path.json`; the `export-trajectory` bundle is the supported way
to read them. **Verify the exact `key` format and `export-trajectory` output layout
against the installed `oc` build** (`oc` is a custom alias); on failure, record in
`AgentResult.errors`. If `oc agent` turns out to support `--format json` for the turn
itself, prefer parsing stdout directly.

### §5.3 Rules (replaces `system_instruction`)

`AgentRules.text` is the operator brief (was the legacy `SYSTEM_INSTRUCTION`). It is a
**binding** — identical across agents for fairness — delivered via each agent's native
mechanism (above). It is **arm-aware**: the "you MUST use your tools" clause is only
valid when tools are granted; the orchestrator resolves the actual text against
`capabilities` (§6). PR3 only delivers whatever `AgentRules.text` it is given.

### PR3 acceptance

- [ ] `agents/capabilities/` provides `SupportsMcp/SupportsSkills/SupportsRules`
      Protocols + mixins and the `McpBinding/SkillBinding/AgentRules` types.
- [ ] No GKE strings anywhere in `agents/` code (tools, skills paths, server names all
      arrive as bindings).
- [ ] MCP and skills are independently controllable; Rules delivered natively per agent.
- [ ] Interim PR1/PR2 config fields (`AGENT_ALLOWED_TOOLS`, skills dir) are migrated
      into bindings and removed. ruff clean. Tests green (incl. `isinstance` Protocol checks).

## 6. Out of scope here — the orchestrator PR (separate, after PR3)

Do **not** include these in PRs 1–3. They belong to `harness/` and `metrics/`:

- `harness/default.py`: build `AgentConfig` (incl. resolved `capabilities`) from
  **task requirements × run arm**; own the **GKE catalog** (the `McpBinding` for the
  GKE MCP + tool names, the GKE `SkillBinding`); resolve **arm-aware `AgentRules`**;
  run **capability negotiation** (`isinstance(agent, RequiredProtocol)` before
  provisioning); call `agent.run(prompt)`; record `capabilities_granted` on the result;
  return `result.to_dict()`. Drop the dead `{"cluster": ...}` context construction.
- `metrics/pipeline.py`: read `capabilities_granted` instead of `BENCH_USE_MCP`
  (closing the regression end-to-end); derive `tools_used`/`skills_used` from the
  canonical `trajectory`; drop the never-read `skills` field.

These two close the `BENCH_USE_MCP` drift completely (single recorded source feeding
both agent and scorer) and finish removing the derived pseudo-results.

## 7. Invariants (every PR)

- **Green per PR:** ruff + the full unit suite pass on each PR independently; the tree
  is never left broken between stacked PRs.
- **Independently reviewable:** each PR is a coherent, self-contained change.
- **Stacked-draft conventions:** keep PRs **draft**; peer-review per `pr-plan.md`; do
  not mark ready out of stage order; retarget to `gke-labs/main` when the stage merges.
- **No GKE specifics in agent code** (tool names, server paths, skill dirs) from PR1's
  interim env field onward; fully via bindings by PR3.
- **Timeouts** on every external call (subprocess / SSH-free local / API turns).
- **Lazy heavy imports** (`deepeval`, `mcp`) — never at module import time.
- **Canonical trajectory** (`ToolCall`) emitted by every agent.
- **Typed results** (`AgentResult`); never hand-roll the dict in implementations.
- **Docstrings:** Google style, concise (purpose + Args/Returns + gotchas/Raises).
- **Verify external CLIs against the installed binaries** (`gemini -o stream-json`,
  `oc agent --help`, `oc sessions …`) before relying on flags/schemas; surface
  extraction failures in `AgentResult.errors`, never silent-empty.

## 8. Branching / stacking quick reference

| PR | Branch | Stacks on | Reworks |
|---|---|---|---|
| PR1 | `feat/devops-bench-agents` | fork integration base | open PR #5 |
| PR2 | `feat/devops-bench-agents-api` | PR1 | open PR #9 |
| PR3 | `feat/devops-bench-agents-capabilities` | PR2 | new |
| (later) | orchestrator/metrics branch | PR3 | new (see §6) |

Reuse the existing open PR branches for PR1/PR2 (amend/rework in place); create PR3's
branch off PR2's HEAD. Keep the stacked-draft PR description footer used by #5/#9.
