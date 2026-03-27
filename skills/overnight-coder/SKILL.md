---
name: overnight-coder
description: Use when the user wants to autonomously implement an entire backlog, TODO list, or set of tasks overnight without supervision. Triggers on phrases like "implement the backlog", "run overnight", "overnight coder", "implement all these tasks", or when the user provides a TODO/backlog file for fully autonomous implementation end-to-end.
---

# overnight-coder

Implements an entire backlog overnight — one task at a time — using isolated branches, TDD, Codex review, and automatic PRs.

**Announce at start:** "I'm using the overnight-coder skill to implement your backlog."

## Prerequisites

Verify before starting. If any are missing, stop and show the user the README install instructions.

- Superpowers plugin (`superpowers:using-git-worktrees`, `superpowers:test-driven-development`, `superpowers:verification-before-completion`)
- `codex-review-loop` skill at `~/.claude/skills/codex-review-loop/` (https://github.com/eishan05/codex-review-loop)
- Codex CLI: `codex --version` must succeed
- GitHub CLI: `gh auth status` must succeed

## Process

### Step 1: Parse Backlog

Read the backlog file provided by the user (accepts any format — markdown checklist, numbered list, prose, GitHub issues export, etc.). Extract a flat ordered list of task descriptions using your judgment.

Present the extracted list and confirm:

> "I found N tasks:
> 1. Add user authentication
> 2. Fix login redirect bug
> 3. Add payment module
> Does this look right? (y/n or edit)"

Do not proceed until the user confirms.

### Step 2: Check for Previous Run

Look for `{STATE_FILE}` in the repo root.

If found, ask:

> "Found previous run: N/M tasks complete, X failed. Resume? (y/n)"
> (Read from state file: N = count of `done`, M = total tasks, X = count of `failed`)

- **Yes:** Skip `done` tasks. Reset `in_progress` → `pending` (agent may have been mid-flight). For `failed` tasks: reset `attempts` to 1 and status to `pending` — they get one fresh attempt; if that attempt also fails (attempts reaches 2), mark permanently `failed`.
- **No:** Overwrite state file, start fresh.

### Step 3: Ask Merge Preference

**Skip this step if resuming** — read `merge_preference` from the existing state file instead.

Ask via `AskUserQuestion`:

> "Merge preference: **autonomous** (auto-merge PRs to main after Codex review) or **review** (leave PRs open for you to review)?"

Store as `autonomous` or `review`.

### Step 4: Initialize State File

**Skip this step if resuming** — the existing state file already has the task list. Only run this step on a fresh start.

Write to `<repo-root>/{STATE_FILE}`:

```json
{
  "backlog_file": "<path provided by user>",
  "merge_preference": "<autonomous|review>",
  "tasks": [
    { "id": 1, "description": "<task text>", "status": "pending", "attempts": 0 }
  ]
}
```

### Step 5: Per-Task Loop

Repeat sequentially for each `pending` task:

**5a. Mark in progress and compute branch name**

Mark task `in_progress`, increment `attempts`, write state file.

Compute branch name: take the task description, lowercase it, replace all spaces and non-alphanumeric characters with hyphens, collapse multiple hyphens into one, truncate the slug to 40 characters, then prefix with `overnight/` (total branch name will be up to 49 characters).

Examples:
- `"Add user auth with JWT"` → `overnight/add-user-auth-with-jwt`
- `"Fix bug: login redirect (prod)"` → `overnight/fix-bug-login-redirect-prod`

**5b. Build and dispatch implementer**

Read `implementer-prompt.md` (in the same directory as this file). Replace all four placeholders:

Determine `{{REPO_PATH}}` by running `git rev-parse --show-toplevel` in the current working directory.

| Placeholder | Value |
|---|---|
| `{{TASK_DESCRIPTION}}` | The task description text |
| `{{REPO_PATH}}` | Absolute path to the repo root |
| `{{BRANCH_NAME}}` | The computed branch name |
| `{{MERGE_PREFERENCE}}` | `autonomous` or `review` |

Dispatch a `general-purpose` Agent with the filled prompt.

**5c. Handle the result**

The agent's last line will be one of:

- `DONE_MERGED` → mark task `done`, no PR URL
- `DONE <url>` → mark task `done`, save `pr_url: <url>`
- `FAILED <reason>` → if `attempts < 2`, reset to `pending` and go back to 5a (one retry); if `attempts >= 2`, mark `failed` with `reason: <reason>`
- Any other output → treat as `FAILED <raw last line of response>`

Write state file after each result.

**5d. Compact context**

Call `/compact` to compress accumulated context.

Then immediately re-read `{STATE_FILE}` to restore the task list (compaction may clear working memory).

Continue to the next `pending` task.

### Step 6: Final Summary

When no `pending` tasks remain, print:

```
overnight-coder complete.
✓ Done:   <N>
✗ Failed: <N>
  Total:  <N>

Failed tasks:
  - "<description>": <reason>

PRs created:
  - <url>
  - <url>
```

Omit the "Failed tasks:" section if there are no failed tasks. Omit "PRs created:" if no PRs were left open (e.g., all merged via `autonomous` mode).

## Red Flags

**Never:**
- Proceed without user confirming the extracted task list
- Skip asking merge preference
- Dispatch implementers in parallel (sequential only — branch conflicts)
- Forget `/compact` between tasks
- Forget to re-read state file after `/compact`
- Start if any prerequisite is missing
