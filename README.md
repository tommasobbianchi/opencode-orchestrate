# opencode-orchestrate

A [Claude Code](https://claude.com/claude-code) skill for **token-frugal coding**:
Claude acts as **planner, orchestrator, and reviewer** while delegating the
agentic execution (reading/writing files, edits, running tests) to the
[opencode](https://github.com/sst/opencode) CLI (DeepSeek V4), invoked
non-interactively.

The idea: every byte of code Claude reads or writes is an avoidable cost. Claude
writes precise specs and reviews diffs; opencode does the file-level work.

## Roles

| Role | Who | Does | Does NOT |
|---|---|---|---|
| Planner | Claude | Decomposes the task, writes precise specs | Doesn't read the files opencode will edit |
| Orchestrator | Claude | Launches opencode via `oc_run.sh`, drives iterations | Doesn't write code directly |
| Executor | opencode (DeepSeek V4) | Reads, edits, writes, runs tests | Doesn't decide architecture, doesn't `git push` |
| Reviewer | Claude | Reviews via `git diff`, checks test exit codes | Doesn't re-read whole files |

## Contents

- `SKILL.md` — the skill definition (trigger phrases, protocol, token-economy rules).
- `scripts/oc_run.sh` — non-interactive opencode wrapper returning a compact,
  token-cheap tail (exit code, log path, last ~60 ANSI-stripped lines).
- `scripts/oc_stats_report.sh` — nightly DeepSeek cost report helper.

## Install

Drop the folder into `~/.claude/skills/opencode-orchestrate/` and ensure
opencode is installed via npm (`npm i -g opencode-ai`; the snap build fails
under systemd-hardened shells). Auth with DeepSeek (`opencode auth login` or
`DEEPSEEK_API_KEY`).

## Requirements

- Claude Code
- opencode CLI (`~/.npm-global/bin/opencode`), DeepSeek auth
- `script(1)` (opencode hangs without a TTY on non-interactive runs)
