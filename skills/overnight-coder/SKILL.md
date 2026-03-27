---
name: overnight-coder
description: Use when the user wants to autonomously implement an entire backlog, TODO list, or set of tasks overnight without supervision. Triggers on phrases like "implement the backlog", "run overnight", "overnight coder", "implement all these tasks", or when the user provides a TODO/backlog file for fully autonomous implementation end-to-end.
---

# overnight-coder

Implements an entire backlog overnight — one task at a time — using isolated branches, TDD, Codex review, and automatic PRs.

**Announce at start:** "I'm using the overnight-coder skill to implement your backlog."

## Prerequisites

**Announce:** `"[Preflight] Checking prerequisites..."`

Verify before starting. If any are missing, stop and show the user the README install instructions.

- Superpowers plugin (`superpowers:using-git-worktrees`, `superpowers:test-driven-development`, `superpowers:verification-before-completion`)
- `codex-review-loop` skill at `~/.claude/skills/codex-review-loop/` (https://github.com/eishan05/codex-review-loop)
- Codex CLI: `codex --version` must succeed
- GitHub CLI: `gh auth status` must succeed

## Process

### Step 0: Parallel Mode Check

If your prompt includes `STATE_FILE: <filename>`, you are running as a **parallel worker**. Set `STATE_FILE` to the provided filename and skip directly to Step 1.

Otherwise, ask the user via `AskUserQuestion`:

> "Run tasks in **parallel** (groups independent tasks into batches and runs batches simultaneously — faster for large backlogs) or **sequential** (one task at a time, default)?"

- **Sequential:** Derive `BACKLOG_SLUG` from the backlog filename: strip extension, lowercase, replace non-alphanumeric characters with hyphens, collapse multiple hyphens (e.g., `TODO.md` → `todo`, `Sprint 3 Tasks.txt` → `sprint-3-tasks`). Set `STATE_FILE = overnight-coder-state-{BACKLOG_SLUG}.json`. Proceed to Step 1.
- **Parallel:** Proceed to Parallel Mode Setup below.

#### Parallel Mode Setup

**1. Check for an in-progress parallel run**

Look for any files matching `overnight-batch-*.md` in the repo root. If found, derive `BACKLOG_SLUG` from the current backlog filename and read each corresponding `overnight-coder-state-{BACKLOG_SLUG}-{group}.json` (if it exists) to determine which groups are incomplete (have pending or in_progress tasks, or have no state file yet).

If incomplete groups are found, ask:

> "Found a previous parallel run. Incomplete groups: auth, ui. Resume them? (y/n)"

- **Yes:** Skip to step 4, re-using existing batch files. Only spawn workers for incomplete groups.
- **No:** Delete all `overnight-batch-*.md` files from the repo root and proceed to step 2.

**2. Invoke grouper subagent**

Read `grouper-prompt.md` (in the same directory as this file). Replace both placeholders:

| Placeholder | Value |
|---|---|
| `{{TODO_FILE}}` | The backlog file path provided by the user |
| `{{REPO_PATH}}` | Output of `git rev-parse --show-toplevel` |

Dispatch a `general-purpose` Agent with the filled prompt.

**3. Present grouping for approval**

The grouper returns named groups. Present them to the user:

> "Proposed parallel groups:
> - **auth** (tasks 1, 3, 5): Authentication and session handling
> - **ui** (tasks 2, 4): Frontend components
> - **api** (tasks 6, 7, 8): REST API endpoints
>
> Proceed with this grouping? (y/n or describe adjustments)"

Do not proceed until the user confirms. If the user requests adjustments, re-describe the grouping with their changes and confirm again.

**4. Write batch files**

For each group, write its `content:` block to `<repo-root>/overnight-batch-{name}.md`.

**4.5. Sleep announcement**

Run this command to prevent the Mac from sleeping:

```bash
caffeinate -i &
```

Then print:

```
All set! You can go to sleep now. 🌙 Good night!

I'll work through your N tasks across M parallel groups while you rest.
See you in the morning with a full summary.

⚡ Don't forget to plug your Mac into a power source before you go!
```
(Replace N and M with actual task count and group count.)

**5. Spawn parallel workers**

Read the full contents of this file (SKILL.md). For each group, construct a worker prompt:

```
You are a parallel overnight-coder worker.
Backlog file: <repo-root>/overnight-batch-{name}.md
STATE_FILE: overnight-coder-state-{BACKLOG_SLUG}-{name}.json
(BACKLOG_SLUG is derived from the original backlog filename: e.g. TODO.md → todo)
Skip Step 0 — you are already in parallel worker mode (STATE_FILE is set above).

---

[full SKILL.md contents here]
```

Dispatch **all workers simultaneously** as parallel `general-purpose` Agent calls in a single message.

**6. Wait and collect results**

Wait for all workers to complete. Collect their final output (the full text of their Step 6 summary).

**7. Print combined summary and end**

```
overnight-coder complete (parallel: N groups).

[auth]  ✓ 3 done  ✗ 0 failed
[ui]    ✓ 1 done  ✗ 1 failed — "Add dark mode": CSS module not found
[api]   ✓ 3 done  ✗ 0 failed

TOTAL: 7 done, 1 failed, 8 total

PRs created:
  - <url>
  - <url>
```

**END** — do not continue to Step 1.

### Step 1: Parse Backlog

**Announce:** `"[Step 1/6] Parsing backlog..."`

Read the backlog file provided by the user (accepts any format — markdown checklist, numbered list, prose, GitHub issues export, etc.). Extract a flat ordered list of task descriptions using your judgment.

Present the extracted list and confirm:

> "I found N tasks:
> 1. Add user authentication
> 2. Fix login redirect bug
> 3. Add payment module
> Does this look right? (y/n or edit)"

Do not proceed until the user confirms.

### Step 2: Check for Previous Run

**Announce:** `"[Step 2/6] Checking for a previous run..."`

Look for `{STATE_FILE}` in the repo root.

If found, ask:

> "Found previous run: N/M tasks complete, X failed. Resume? (y/n)"
> (Read from state file: N = count of `done`, M = total tasks, X = count of `failed`)

- **Yes:** Skip `done` tasks. Reset `in_progress` → `pending` (agent may have been mid-flight). For `failed` tasks: reset `attempts` to 1 and status to `pending` — they get one fresh attempt; if that attempt also fails (attempts reaches 2), mark permanently `failed`.
- **No:** Overwrite state file, start fresh.

### Step 3: Ask Merge Preference

**Announce:** `"[Step 3/6] Configuring merge preference..."`

**Skip this step if resuming** — read `merge_preference` from the existing state file instead.

Ask via `AskUserQuestion`:

> "Merge preference: **autonomous** (auto-merge PRs to main after Codex review) or **review** (leave PRs open for you to review)?"

Store as `autonomous` or `review`.

### Step 4: Initialize State File

**Announce:** `"[Step 4/6] Initializing state file..."`

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

**Announce:** `"[Step 5/6] Starting task loop — N tasks queued."`

**Sleep announcement (sequential mode only — skip if running as a parallel worker)**

Run this command to prevent your Mac from sleeping during the overnight run:

```bash
caffeinate -i &
```

Then print:

```
All set! You can go to sleep now. 🌙 Good night!

I'll work through your N tasks while you rest.
See you in the morning with a full summary.

⚡ Don't forget to plug your Mac into a power source before you go!
```
(Replace N with the actual pending task count.)

Repeat sequentially for each `pending` task:

**5a. Mark in progress and compute branch name**

**Announce:** `"[Task N/M] Starting: <task description>"`  (N = current task number, M = total tasks)

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

**Announce:** `"[Step 6/6] All tasks complete! Generating summary..."`

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
- Dispatch implementers in parallel **within a single overnight-coder instance** (sequential only within each batch — branch conflicts)
- Forget `/compact` between tasks
- Forget to re-read state file after `/compact`
- Start if any prerequisite is missing
- Ask the parallel mode question in Step 0 if `STATE_FILE` was provided in your prompt context (you are a worker, not the orchestrator — skip Step 0 entirely)
