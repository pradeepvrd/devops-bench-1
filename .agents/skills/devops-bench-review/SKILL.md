---
name: devops-bench-review
description: >
  Use when the user asks for a CODE review of devops-bench changes — e.g.
  "review this PR", "review my changes", "review the working tree", "code-review
  this diff", "review this skill / AGENTS.md change", "is this
  harness/deployer/metric change sound". Reviews a PR (number/URL) or the
  current working tree and returns ranked findings with severity, file:line
  evidence, and a concrete fix. Review-only: static analysis plus unit tests,
  ruff, and format checks; it NEVER runs benchmark evals or provisions infra.
  For a NEW or CHANGED benchmark task (task.yaml + its stack), use the sibling
  `task-review` skill instead.
---

# devops-bench code review

Review a **GitHub PR** or the **current working tree** as *code*, then return
ranked findings a maintainer would act on. Each finding is
**severity (blocker / major / minor / nit) + `file:line` evidence + a concrete,
actionable fix**, scoped to the change. Do not nitpick; do not invent findings to
fill a quota. If nothing survives, say so.

`devops_bench/` is the canonical pipeline. The top-level `deployers/` and
`skills/` directories hold a placeholder `README.md` each; `scripts/` holds the
bastion and matrix shell scripts. The live Python is under `devops_bench/`. For
the registries and lifecycle, read
[architecture](../../../docs/components/architecture.md) and
[glossary](../../../docs/components/glossary.md) rather than reconstructing them.

**Defer task-specific concerns** — schema/metadata, spec parsing, outcome rubrics,
and the per-task parallel-safety of cloud resource names — to the
[task-review](../task-review/SKILL.md) skill. This skill reviews code.

## Scope & guardrails — review only

Analyze and report. Do **not** execute the benchmark, and never provision infra.

- **May run** (only to validate the code under review): unit/integration tests for
  the changed code (`uv run pytest`), `uv run ruff check .`, and
  `uv run ruff format --check .`. Report violations; do not reformat files as part
  of the review.
- **Must NOT run:** `python -m devops_bench`, the matrix scripts, any agent/judge
  invocation, or `tofu`/`gcloud`/`kind`/`kubectl` apply/destroy. If judging a
  change seems to *require* running it, report what static analysis shows and state
  that an actual eval is out of scope.

If a lens needs a capability (sub-agent for an independent verifier pass, etc.),
express the need generically and consult
[harness-capabilities](../../references/harness-capabilities.md); degrade to
doing it inline. The same file has the permission-profile shape for enforcing
the review-only boundary with tool permissions rather than trust.

## Gather the diff

- **A PR** (number/URL): `gh pr view <pr> --json title,body,baseRefName,headRefOid,changedFiles`
  and `gh pr diff <pr>`. Read enclosing code from this checkout when it is already on
  the PR branch; otherwise `gh pr checkout <pr>`, or read one file at the PR head with
  `git show <headRefOid>:<path>` after a `git fetch` — the object is not local until
  you fetch it.
- **Working tree:** `git diff @{upstream}...HEAD` (or `main...HEAD`) **plus**
  `git diff HEAD` for uncommitted work — review is often pre-commit. Treat the union
  as scope.

The diff is the scope. For each touched function, also read the enclosing function:
a bug on an unchanged line of a touched function is in scope (the change re-exposes
or fails to fix it).

## Lenses

Apply the lenses that fit the change. Every change gets the CodeRabbit
guidelines below — lenses of equal standing with the rest. Most code wants
Correctness, Testability, and Conventions; library/registry surfaces add API
hygiene and Domain modeling. Changes touching `devops_bench/` or `docs/` always
add Vendor neutrality. Changes touching `.agents/**` or any `AGENTS.md` add
Agent-facing docs.

### CodeRabbit guidelines — read them live

Read `.coderabbit.yaml` at the repository root and apply its review guidelines
as part of this review:

- `reviews.instructions` — repo-wide review rules; apply them to everything in
  scope.
- `reviews.path_instructions` — a list of entries; apply each entry's
  `instructions` to the files in scope matching its `path` glob.
- `reviews.path_filters` — skip the files CodeRabbit excludes.

`.coderabbit.yaml` derives its rules from [AGENTS.md](../../../AGENTS.md)
(`knowledge_base.code_guidelines`). If `.coderabbit.yaml` or those keys are
missing, read [AGENTS.md](../../../AGENTS.md) directly for the repo-wide rules
(the config's path-specific instructions have no fallback), apply this skill's
lenses, and name in the review output which source you used.

### Correctness

Logic and edge cases: inverted/off-by-one conditions, null/empty/missing-key paths,
falsy-zero checks, missing `await`, swallowed exceptions, wrong-variable copy-paste,
`set -euo pipefail` gaps in bash. **No hallucinated APIs** — every called function,
attribute, registry key, env var, and CLI flag must exist (Grep the symbol; check
the registry decorator). For each deleted/replaced line, name the invariant it
enforced and confirm it is re-established elsewhere — a dropped guard or error path
is a finding. For each changed function, check callers/callees: does a new
precondition, changed return shape, or new exception break a call site?

### Testability

New or changed logic should have tests that **would actually fail on breakage** —
not tautological (asserting the mock returned what the mock was told to return,
re-deriving the expected value with the code under test, or `assert x == x`). Check
edge coverage (empty, error, boundary), not just the happy path. Flag new
non-trivial logic with **no test** as a finding, and name the test that should
exist. Note when code is hard to test because a dependency is hard-wired rather
than injected.

### Maintainability

Complexity and over-engineering: speculative config/flags/abstraction for a future
that isn't here, parameters no caller passes, premature generalization. Respect the
layering — `core/ → {models, providers, deployers, agents, chaos, verification,
metrics} → evalharness/`. An inward import (e.g. `core/` importing `evalharness/`,
or one sibling reaching into another's internals) is a finding; name the seam it
should cross instead. Prefer the smallest change that solves the actual problem.

### API hygiene / design

Public surfaces should be clear and stable: an extension axis is added by
**registering a class via the matching decorator** (`AGENTS`, `MODELS`, `PROVIDERS`,
`FAULTS`, `TRIGGERS`, `VERIFIERS`, `METRICS`) — flag a change that edits the engine
to special-case a new variant instead of registering it. No leaky abstractions
(callers depending on internals, or a return type that exposes implementation).
Watch `__all__` / signature changes that break the public contract without reason.

### Domain modeling

Types should model the domain. The repo already has the right vocabulary — `Task`,
`AgentResult`, `ClusterInfo`, `RunContext`, `RunEnv`, `MetricScore`,
`VerificationSpec`. Flag **primitive obsession** where one of these (or a small new
dataclass) belongs: a bare `dict`/`tuple`/positional-string passed across a seam
that a typed object would make self-describing and validate-once. Flag stringly-typed
state that should be an enum, and parallel lists that should be one list of records.

### Conventions

- **Tooling:** `uv run …` / `uv add …`, never bare `pip`/`python` — repo-wide,
  including `hack/` and `scripts/`, which the config's path globs don't reach.
- **Lint:** run `uv run ruff check .`; pyproject.toml is the source of truth
  for the rule set.
- **Docstrings:** Google style — purpose; `Args` / `Returns` / `Attributes`;
  `Raises`; concise, no implementation narration. Not linted and not in
  `.coderabbit.yaml` — check it by reading.
- **Comments — over-commenting is a finding.** Self-documenting code needs no
  running commentary. Flag any comment that **narrates what the code does**
  (`# loop over the items`, `# increment counter`, a docstring-restating-the-body).
  Keep a comment only when it explains a genuinely **non-obvious edge case or
  intent** the code can't show (a `409`-on-re-run workaround, a length-limit
  rationale). When you flag one, say whether the fix is "delete it" or "rewrite it
  to explain the *why*".

### Vendor neutrality — structural checks

`.coderabbit.yaml` states the terminology and env-var rules, but it keys on
strings and names. The checks below catch what survives a string match —
**run them on every change touching `devops_bench/` or `docs/`.** For the
cloud-provider vs model-provider split (only the cloud axis is policed), see
[glossary.md](../../../docs/components/glossary.md).

- **Log strings, not just raised errors.** The config covers error messages;
  log lines are the most-missed surface, because the code is neutral and only
  the string is not: `"could not reach the GKE cluster"` emitted from `core/`
  should read `"could not reach the cluster"`.
- **Defaults and fallbacks.** A neutral parameter that quietly defaults to one
  provider (`location="us-central1"`, `provider="gcp"`) hard-codes a vendor
  through the back door. The established pattern is deduction that *raises*
  rather than falls back — see [infra.md](../../../docs/components/infra.md).
- **Names on public surfaces.** A field, class, or CLI flag named for one
  provider fixes the vocabulary for every future provider. The surface is
  already neutral — `--project` / `--cluster` in `cli.py`, `project_id`,
  `cluster_name` — so what to catch is a *new* name that reintroduces a vendor,
  not the ones already there.
- **Docs and docstring examples.** An example is user-facing text. Where a
  provider-specific example is genuinely clearest, label it as one rather than
  letting it read as the only way.
- **Env-var reads — which module, not which words.** The config names the
  variables; it cannot see where the read lives. Grep the diff for `get_env(`
  and `os.environ` and check the module: `GCP_PROJECT_ID`, `GOOGLE_CLOUD_*`,
  `GKE_*` resolved in a generic layer is a finding even when the surrounding
  prose is neutral. Provider resolution belongs behind the `PROVIDERS`
  registry.
- **Two task trees.** The config's `tasks/<provider>/` carve-out is the on-disk
  task tree at the repo root, which is a different thing from the
  `devops_bench/tasks/` schema package — the latter is a generic layer. Write
  the pattern, not the instance: the carve-out is `tasks/<provider>/`, so
  `tasks/aws/` is as exempt as `tasks/gcp/` the day someone adds it.

Give the neutral replacement, not just the objection: "cloud project id",
"target Kubernetes cluster", "the configured provider". Over-flagging trains
authors to ignore the lens.

### Security

Secrets and inputs: no committed credentials, keys, or tokens (Grep the diff for
obvious patterns); secrets read from env/secret-store, not hardcoded; user/agent/
task-supplied strings that reach a shell are passed argv-style, never
interpolated into a shell string — validation does not make interpolation safe,
so an allowlist is an extra check rather than a substitute, and `shell=True`
with untrusted input is always a finding; no path traversal from un-sanitized names. Flag a
secret echoed into logs.

### Agent-facing docs (skills, AGENTS.md, references)

Apply when the diff touches `.agents/**` or any `AGENTS.md`. These files are
instructions an agent executes — review them as interfaces, not prose:

- **Audience.** Every sentence tells the executing agent what to do, how to do
  it, or the context needed to do it. Flag design rationale, maintainer or
  author asides, and a document narrating its own structure or history.
- **Frontmatter is a pointer, paid on every load.** The description carries
  invocation triggers, a one-line identity, and handoffs to sibling skills.
  Flag body content restated there — rule lists, key names, counts that can
  desync from the body. `name:` matches the directory.
- **Single source of truth.** Flag restated config, code, or command output
  the agent could read live or reach by pointer. A copy is justified only when
  the lookup is expensive or the convention is unwritten — the gotcha, the why.
- **Right-sized loading.** Material every run needs is inline; material only
  some paths need sits behind a link. Flag a section that only one path reads
  growing to dozens of lines — move it behind a link.
- **Checkable completion.** Steps end on a bound the agent can test ("every
  touched function's callers checked"). Flag vague bounds ("ensure quality") —
  they invite stopping early. Prefer bounds that are also demanding — "every
  rule in the config applied" forces legwork where "produce a list" does not.
- **Positive instructions.** State the target behavior. Keep a prohibition
  only as a hard guardrail, paired with what to do instead.
- **No-ops.** Flag adjective-only instructions that name no step, check, or
  bound ("be careful", "be thorough") — they spend load and change nothing.
- **Co-location.** One concept's definition, rules, and caveats live under one
  heading. Flag a meaning fragmented across sections.

## Verify, then present

Dedup candidates pointing at the same mechanism. For each survivor, run an
independent verifier pass on non-obvious ones (a sub-agent if available, else
re-check yourself) and try to **refute** it by finding the guard/test/type that
already covers it. To corroborate, you **may** run `uv run pytest` and
`uv run ruff check .` — **pre-existing failures on untouched code are not the
author's** (note them as context, not findings). Drop anything refuted.

Present a readable review (not raw JSON):

1. **Overview** — 1–2 sentences on what the change does.
2. **Findings**, most-severe first, each as
   `severity — file:line — summary` then a one-line failure/why and the concrete
   fix, and **how to verify** (the test to add/run, the ruff rule, the call site to
   check).
3. **Cleared** — a short list of what you checked and found sound, so the author
   knows the coverage.
4. **Systemic note** (when applicable) — if several findings share a root cause,
   recommend the seam-level fix once instead of per-site patches.
