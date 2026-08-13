---
name: opencode-orchestrate
description: Token-frugal coding — the assistant plans, orchestrates and reviews while an executor CLI (opencode, DeepSeek) does the file reading, editing and test running. Use when the user wants to save tokens on implementation work, offload coding to a cheaper model, or says any of "offload to opencode", "delegate this", "use opencode for", "/opencode", "orchestrator mode", "planner orchestrator reviewer", "delega a opencode", "fai fare a opencode", "risparmia token". Use proactively for implementation-heavy tasks (bulk edits, scaffolding, mechanical refactors, test writing, well-specified features) where most of the token cost would be reading and rewriting files.
license: MIT
metadata:
  version: 2.0.0
  author: tommaso
  domains: [delegation, code-review, cost-control, agent-orchestration]
---

# opencode-orchestrate — you plan and review, the executor types

## Roles

| Role | Who | Does | Does NOT |
|---|---|---|---|
| **Planner** | you | decomposes the task, writes precise specs | read the files the executor will modify |
| **Orchestrator** | you | launches the executor, manages iterations | write code directly |
| **Executor** | opencode (DeepSeek) | reads files, edits, writes, runs the tests | decide architecture, or touch git |
| **Reviewer** | you | reviews by `git diff`, trusts the test exit code | re-read whole files |

**The goal is to minimise the tokens you spend.** Every byte of code you read or write is
an avoidable cost — the executor is what touches the code.

## Pre-flight, every time

```bash
OC=~/.npm-global/bin/opencode          # the npm build; a confined snap install fails
$OC --version                          # under a hardened shell
$OC providers 2>&1 | head -5           # is auth present?
cd <REPO> && git rev-parse HEAD && git status --porcelain | head
```

- **No auth** → STOP and ask. Do not proceed blind.
- **Dirty tree** → say so before delegating, and record the starting HEAD for rollback.
- The executor inherits its own config and instruction files, so workers start with context
  you did not have to pay for.

## Protocol

### 1 — PLAN (frugally)

Build the picture WITHOUT reading sources in full: `tree -L 2`, `grep -rln <symbol>`, a code
map if you have one. Read signatures and interfaces at most.

Write the spec to a file. Every spec MUST carry:

- **exact paths** that may be created or modified
- **exact symbols** to introduce or change
- **concrete acceptance criteria** — observable behaviour
- the **verification command** the executor runs *itself*, and the instruction to iterate to green
- **limits**: "touch nothing outside \<scope\>", "no commits, no pushes"

### 2 — DELEGATE

```bash
RUN=<skill>/scripts/oc_run.sh
$RUN -d ~/projects/<repo> -t <task-title> -T 600 -p /tmp/oc-task-1.md
```

**Model choice (`-m`).** At PLAN time you already know whether the task is mechanical or
subtle, so route it:

- a **cheap/fast** model for single-file work, scaffolding, mechanical edits, test writing
  against a clear spec — much cheaper, and the coding gap is near-invisible;
- a **strong** model for multi-file refactors, cross-file invariants and long agentic chains,
  where one mistake costs a whole ITERATE cycle;
- when unsure, or when the cheap run fails REVIEW: re-delegate to the strong one.

Operational rules:

- The wrapper returns an exit code, a log path and a compact tail. **Read only the tail.**
  The full log is on disk for the doubtful cases.
- **There is no parallelism. One worker at a time.** An earlier version of this skill said
  parallel runs were fine on distinct worktrees. That was WRONG and produced a silent
  failure: of three concurrent runs with distinct `-d`, one did all the work, two exited 0
  having changed nothing, and one worker's log contained another worker's complete
  transcript. The suspected shared state is the executor's session store, which a distinct
  working directory does not isolate. `oc_run.sh` now takes a per-user lock and refuses a
  second run with exit 3. Parallelism belongs in PLANNING, never in execution.
- **Exit 0 is not evidence that anything happened.** Both starved workers exited 0 with an
  empty diff. The wrapper now warns when the target tree is clean after a run; if you see
  that warning, read the tail before believing the task is done.
- Serial tasks in the same repo: continue the last session with `-c`; with several sessions
  use `-s <sessionID>` to resume a specific one.

### 3 — REVIEW, by diff, never by whole files

```bash
git diff --stat                  # shape first: which files, how much
git diff -- <suspect-file>       # merit second, only where it matters
<test command>; echo "RC=$?"     # trust the exit code, don't re-read the tests
```

Checklist: scope respected? files outside the spec touched? required symbols present
(`grep -n`)? tests green? no secrets in the diff?

And read deviations before rejecting them. An executor that says *"I did X instead, here is
the measurement that shows why"* has just caught an error in your spec — which is the single
most valuable thing it can do.

### 4 — ITERATE (3 cycles maximum)

A failed review gets a MINIMAL corrective prompt — what is wrong and what is expected, never
a restatement of the spec:

```bash
echo "Test X fails with <error>. Fix ONLY <file>: <expectation>." | \
  $RUN -d ~/projects/<repo> -c -t <task-title>-fix
```

After 3 failed cycles → STOP. Report the partial diff, the error and the options. Do not
burn tokens in a loop.

### 5 — REPORT

Summary of what changed (`git diff --stat`), test outcome, iteration count, executor cost,
and the rollback command against the HEAD you recorded — to be run only on explicit
confirmation.

## Hard rules of token economy

1. NEVER read in full a file the executor will create or modify.
2. Review ALWAYS by diff: `--stat` first, targeted diff after.
3. The executor runs the tests; you check the exit code.
4. Corrections via `-c` on the warm session, never a fresh spec.
5. Executor output: the wrapper tail only.
6. Specs surgical and short: paths, symbols, acceptance. No prose.

## What NOT to delegate

- Architectural decisions, ambiguous refactors with cross-file invariants, security review.
- Irreversible operations — push, deploy, migrations, `rm -rf`, service changes. Those stay
  with you, and need explicit user confirmation.
- Anything requiring tools only your session has.
- Micro-tasks: if you could do it in 30 seconds, the delegation overhead does not repay.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| sandbox/confinement error on launch | a confined snap install invoked from a hardened shell | use the npm build (the wrapper's default) |
| `Unauthorized: Authentication Fails` | missing executor credential | `opencode auth login`, or set the API key in the environment |
| exit 124 from the wrapper | timeout | raise `-T`, or split the task into smaller specs |
| exit 3 from the wrapper | another run holds the lock | wait; runs are deliberately serial (see DELEGATE) |
| worker touched files outside scope | spec too vague | re-spec with explicit limits, roll back that file |

## Cost reporting

`opencode stats --days 1` gives sessions, cost and token counts for the window.
`scripts/oc_stats_report.sh 1` formats it compactly and `--dry-run` prints without sending,
so it can be wired to whatever notification path you already have — a cron job, a chat
webhook, or nothing at all.
