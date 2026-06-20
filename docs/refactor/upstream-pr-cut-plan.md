# Upstream PR Cut Plan — 8 stacked PRs for gke-labs

**Status:** plan only (not executed). Describes how to re-cut the completed refactor
(currently assembled on the fork branch `refactor/integration`) into **8 clean,
stacked PRs** for `gke-labs/devops-bench`, with the four senior-review fix PRs folded
into their owning component.

---

## 1. Current state (source of truth)

- The entire reconciled refactor lives on `fork/refactor/integration` (fork =
  `pradeepvrd/devops-bench`). It is green: **654 unit tests pass**, `ruff check
  devops_bench/` clean, every test file passes in isolation.
- It was built as reworked component PRs **#11–#18** plus senior-review fix PRs
  **#19–#22**, all already merged **into the fork's `refactor/integration` branch only**
  (never upstream). They therefore show as *Merged* on the fork. The capstone
  **#23** (whole refactor vs. the foundation) is an open draft.
- The pre-refactor Stage-2/3 drafts **#5–#10** are closed as superseded.
- The Stage-1 foundation leaves (tasks / deployers / k8s / models) are upstream PRs
  **#89–#92** (`pradeepvrd:feat/devops-bench-*`). **They must land upstream first** —
  the 8 PRs below stack on top of that foundation.

Because every fix already lives in `refactor/integration`, **folding #19–#22 is
automatic**: when each component PR is re-cut from the final tree, that component's
files already contain its fixes. No cherry-pick of the fix commits is needed.

## 2. Fold mapping (fix PR → owning component PR)

| Fix PR | Commit | Files | Folds into |
|---|---|---|---|
| #20 openclaw orphan-result policy | `78c986e` | `agents/cli/openclaw.py` (+test) | **PR 4 (agents base+cli)** |
| #21 chaos Phase-4 (registry parsing + lazy agent) | `855843e` | `chaos/*` (+tests) | **PR 6 (chaos)** |
| #22 chaos test-isolation | `0ef34b5` | `tests/unit/chaos/test_extension_axis.py` | **PR 6 (chaos)** |
| #19 harness env-snapshot | `59c58ee` | `harness/default.py` (+test) | **PR 8 (harness)** |

## 3. The 8 PRs (stacked, dependency order)

Stack base = the Stage-1 foundation (upstream after #89–#92). Each PR is based on the
previous branch, so each PR's diff is exactly one component and each step builds green.

```
foundation(#89–92)
  └─ PR1 models/loop
       └─ PR2 verification            (carries its own VERIFIERS registry + registry-driven spec)
            └─ PR3 agents/capabilities (bindings/protocols/mixins — leaf, imports core only)
                 └─ PR4 agents base+cli (+#20)   (consumes capabilities)
                      └─ PR5 agents/api          (consumes capabilities + models/loop)
                           └─ PR6 chaos (+#21,#22)
                                └─ PR7 metrics
                                     └─ PR8 harness (+#19)
```

**Ordering rationale (why this is green with final files):**

- `capabilities/` imports only `core`, so it lands **before** base/cli/api (which
  consume the bindings). This is the one re-order vs. the original wave history
  (where capabilities was PR3 *refactoring* base) — landing the bindings leaf first
  lets every later agents PR use the final, binding-consuming files directly.
- `verification/` (PR2) takes the **final** registry-driven `spec.py` + `registry.py`
  (the verifier registry that was originally built in the metrics PR). It is
  self-contained — `VERIFIERS` lives in `verification/registry.py` and needs no metric.
  This shrinks the metrics PR (PR7) to metrics-only.
- `chaos` (PR6) takes the final Phase-4 registry-driven form (so #21/#22 are included
  and `import devops_bench.chaos` pulls no agent/models chain).
- `metrics` (PR7) and `harness` (PR8) come last; harness wires everything.

### Per-PR contents (paths to pull from `refactor/integration`)

| PR | Add these paths (final versions) |
|---|---|
| 1 models/loop | `devops_bench/models/loop.py`, `tests/unit/models/test_loop.py` |
| 2 verification | `devops_bench/verification/**` (incl. `registry.py`, `spec.py`, `runner.py`, `base.py`, `schema.py`, `verifiers/**`, `__init__.py`), `tests/unit/verification/**` |
| 3 agents/capabilities | `devops_bench/agents/capabilities/**`; `devops_bench/agents/__init__.py`; capability-only tests under `tests/unit/agents/` (e.g. `test_agents_capabilities.py`) |
| 4 agents base+cli (+#20) | `devops_bench/agents/base.py`, `result.py`, `config.py`, `cli/**`; agents base/cli/result/config + no-gke tests under `tests/unit/agents/` |
| 5 agents/api | `devops_bench/agents/api/**`, `tests/unit/agents/api/**` |
| 6 chaos (+#21,#22) | `devops_bench/chaos/**`, `tests/unit/chaos/**` |
| 7 metrics | `devops_bench/metrics/**`, `devops_bench/skills/**`, `tests/unit/metrics/**` |
| 8 harness (+#19) | `devops_bench/harness/**`, `complextasks/optimize-scale/task.yaml`, `tests/unit/harness/**` |

> When splitting `tests/unit/agents/` across PRs 3/4/5, assign each test file to the
> earliest PR whose code satisfies its imports (capability-only tests → PR3; base/cli
> tests → PR4; api tests → PR5). If a test imports across levels, move it to the later
> level. Run the per-level checks below to catch mis-assignment.

## 4. Mechanical recipe (snapshot from the final tree)

For each PR, create a branch on the previous tip and check out that component's final
files from `refactor/integration`:

```sh
git fetch fork
FND=fork/integration/devops-bench-stage1     # or origin/main once #89–92 land upstream

# PR1
git checkout -B submit/1-models-loop "$FND"
git checkout fork/refactor/integration -- devops_bench/models/loop.py tests/unit/models/test_loop.py
git commit -am "feat(models): run_tool_loop shared turn-loop primitive"

# PR2 (stacks on PR1)
git checkout -B submit/2-verification submit/1-models-loop
git checkout fork/refactor/integration -- devops_bench/verification tests/unit/verification
git commit -am "feat(verification): discriminated-union spec + deadline runner + VERIFIERS registry"

# PR3 capabilities, PR4 agents base+cli, PR5 api, PR6 chaos, PR7 metrics, PR8 harness
# … same pattern: branch off previous tip, `git checkout fork/refactor/integration -- <paths>`, commit.
```

(`git checkout <ref> -- <paths>` stages the final file content; commit each level.)

## 5. Per-PR acceptance (run before pushing each level)

At each stacked level (cumulative tree), confirm it builds and the included tests pass:

```sh
uv sync
uv run ruff check devops_bench/
uv run pytest tests/unit/<dirs-included-so-far> -q   # e.g. tests/unit/models then +verification …
```

By PR8 the cumulative tree == `refactor/integration`, so the **full suite must be
654 passing** and `ruff check devops_bench/` clean. Also re-confirm isolation for the
chaos extension-axis file: `uv run pytest tests/unit/chaos/test_extension_axis.py -q`.

Invariants to keep green (already satisfied on `refactor/integration`):
- `import devops_bench.<pkg>` pulls no provider SDK / deepeval / mcp (every package).
- `import devops_bench.chaos` does **not** import `chaos.agent` / `models.loop` / `models.base`.
- Registry-only resolution; single `BENCH_USE_MCP` read; results.json D3 schema
  preserved + success/failed key-symmetric.

## 6. Open as draft, then retarget upstream

1. Push each `submit/N-*` branch to the fork; open as **draft** PRs with
   `--base` = the previous branch (PR1's base = the foundation branch).
   `gh pr create --repo pradeepvrd/devops-bench --base <prev> --head submit/N-* --draft`.
2. Review the stack end-to-end (it should equal `refactor/integration`).
3. When the foundation (#89–#92) has landed on `gke-labs/main`, retarget each PR to
   upstream: open them against `gke-labs/devops-bench` (one base-flip per PR, PR1 →
   `main`, PR_N → PR_{N-1}). This is the only step that touches the upstream repo.

## 7. Sanity check that the split is lossless

After cutting PR8's branch, it must be identical to the integration tip:

```sh
git diff fork/refactor/integration submit/8-harness -- devops_bench complextasks tests/unit
# (empty == the 8-PR stack reproduces the reviewed refactor exactly)
```
