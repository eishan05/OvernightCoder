# overnight-coder — Design Spec

**Date:** 2026-03-26
**Status:** Approved

---

## Overview

`overnight-coder` is a Claude Code skill that takes a backlog/TODO document and autonomously implements every task overnight — one at a time — using isolated git worktrees, opening PRs, running a Codex review loop until clean, and either auto-merging or leaving PRs open based on a preference set at startup.

It is designed to run unattended. It saves state between tasks, compacts context to survive long runs, and can resume a previous run if the session was interrupted.

---

## Architecture

Two files:

```
skills/overnight-coder/
  SKILL.md                # Orchestrator — what the user invokes
  implementer-prompt.md   # Injected into each implementer subagent
```

The **orchestrator** is thin: it parses the backlog, manages a state file, dispatches one implementer subagent per task, handles retries, and compacts context between tasks.

The **implementer** is self-contained: it handles worktree setup, implementation, PR creation, codex review, and merge/keep decision end-to-end.

---

## Dependencies

All must be installed before using this skill:

| Dependency | Source |
|---|---|
| Superpowers plugin | Official Claude Code plugin |
| `codex-review-loop` skill | https://github.com/eishan05/codex-review-loop |
| Codex CLI | Installed separately |

**Superpowers skills used by the implementer:**
- `superpowers:using-git-worktrees`
- `superpowers:test-driven-development`
- `superpowers:verification-before-completion`

> Note: `superpowers:finishing-a-development-branch` was considered but not used — it is interactive (presents 4 options to the user) and does not fit the autonomous implementer model. Step 5 of the implementer uses direct `gh pr merge` commands instead.

---

## Orchestrator Design

### Startup

1. Read the backlog file passed by the user (any format — markdown checklist, numbered list, prose, etc.)
2. Use Claude's judgment to extract a flat ordered list of tasks. Present the extracted list to the user and confirm before proceeding (e.g. "I found 8 tasks. Does this look right?")
3. Ask the user (via `AskUserQuestion`): **"Fully autonomous (auto-merge PRs to main) or review mode (leave PRs open for you to review)?"**
4. Check for an existing `overnight-coder-state.json` in the repo root. If found, ask: **"Found a previous run: N/M tasks complete. Resume? (y/n)"**
   - Yes → skip `done` tasks; `failed` tasks get one fresh attempt (if that attempt also fails, the task is permanently marked `failed` and skipped); `in_progress` tasks are reset to `pending` (implementer may have been mid-flight when session died)
   - No → overwrite state file, start fresh

### State File

Saved to `overnight-coder-state.json` in the repo root:

```json
{
  "backlog_file": "TODO.md",
  "merge_preference": "autonomous",
  "tasks": [
    {
      "id": 1,
      "description": "Add user auth",
      "status": "done",
      "pr_url": "https://github.com/...",
      "branch": "overnight/add-user-auth"
    },
    {
      "id": 2,
      "description": "Fix login bug",
      "status": "failed",
      "reason": "Implementer could not resolve conflict in auth.ts after 2 attempts",
      "attempts": 2
    },
    {
      "id": 3,
      "description": "Add payment module",
      "status": "pending"
    }
  ]
}
```

Statuses: `pending | in_progress | done | failed`

### Per-Task Loop

For each `pending` task (sequentially):

1. Mark task `in_progress`, increment `attempts`, save state file
2. Dispatch implementer subagent with:
   - Full task description
   - Repo path
   - Merge preference
   - Branch name: `overnight/<task-slug>` (slug = task description lowercased, spaces/special chars replaced with hyphens, truncated to 40 chars)
3. If implementer returns `FAILED`:
   - Retry once with a fresh subagent (same inputs)
   - If retry also returns `FAILED` → mark task `failed` with reason, log, continue
4. If implementer returns `DONE` or `DONE_MERGED` → mark task `done`, record PR URL if applicable
5. Call `/compact` to compress context
6. Re-read state file (context compaction may clear working memory)
7. Continue to next pending task

### Final Summary

When all tasks are exhausted:

```
overnight-coder complete.
✓ Done:   6
✗ Failed: 2
  Total:  8

Failed tasks:
  - "Add payment module": <reason>
  - "Fix login bug": <reason>

PRs created:
  - https://github.com/...
  - https://github.com/...
```

---

## Implementer Design

Each implementer subagent is dispatched with a filled-in version of `implementer-prompt.md`. It operates fully autonomously and reports back one of:
- `DONE <PR-url>` — PR created, left open
- `DONE_MERGED` — PR created and merged to main
- `FAILED <reason>` — could not complete

### Implementer Lifecycle

**Step 1: Setup**
- Use `superpowers:using-git-worktrees`
- Branch name: `overnight/<task-slug>` (slugify the task description)
- Do not touch the current local branch

**Step 2: Implement**
- Use `superpowers:test-driven-development`
- Work fully autonomously until implementation is complete and tests pass
- Use `superpowers:verification-before-completion` before declaring done

**Step 3: Push + PR**
- Push branch to origin
- Create GitHub PR using `gh pr create` with clear title and summary

**Step 4: Codex Review Loop**

Run using model `gpt-5.4`, reasoning effort `high`. These are defaults set in `implementer-prompt.md` — to override, edit that file before invoking the skill.

```
outer_cycles = 0
WHILE not clean AND outer_cycles < 3:
  outer_cycles++
  Run codex-review-loop (up to 3 iterations internally)

  IF codex found no issues:
    → exit loop, code is clean

  IF 3-iteration cap reached AND fixes were applied during this run:
    → start a NEW codex-review-loop session (fresh context, fresh 3 iterations)
    → codex gets a clean look at the latest code state

  IF 3-iteration cap reached AND implementer judges remaining issues
     are already addressed or not worth fixing:
    → exit loop, declare clean

IF outer_cycles == 3 AND still issues remain:
  → exit loop, declare clean (hard cap reached)
```

**Hard cap:** Maximum 3 outer cycles (each up to 3 iterations) = at most 9 total Codex review passes per task.

**Step 5: Finish**
- If merge preference = `autonomous`:
  - Merge PR to `main`
  - Clean up worktree
  - Return `DONE_MERGED`
- If merge preference = `review`:
  - Leave PR open
  - Clean up worktree
  - Return `DONE <PR-url>`

---

## File Layout (repo)

```
overnight-coder/
  README.md                           # Install instructions + prerequisites
  skills/
    overnight-coder/
      SKILL.md                        # Orchestrator skill
      implementer-prompt.md           # Implementer subagent prompt template
  docs/
    superpowers/
      specs/
        2026-03-26-overnight-coder-design.md   # This file
```

---

## Non-Goals

- Dependency detection between tasks (sequential order is sufficient)
- Parallel task execution (sequential only, by design)
- Multi-repo support (single repo only)
- Interactive clarification during implementation (implementers are fully autonomous)
