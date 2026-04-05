---
name: overnight-coder
description: Use when the user wants to autonomously implement an entire backlog overnight without supervision. Requires a backlog FILE (markdown checklist, numbered list, GitHub issues export, etc.) — inline task lists are not supported. Triggers on phrases like "implement the backlog", "run overnight", "overnight coder", "implement all these tasks", or when the user provides a TODO/backlog file for fully autonomous implementation end-to-end.
---

# overnight-coder

Implements an entire backlog overnight — one task at a time — using isolated branches, TDD, Codex review, and automatic PRs.

**Announce at start:** "I'm using the overnight-coder skill to implement your backlog."

## Prerequisites

**Announce:** `"[Preflight] Checking prerequisites..."`

Add the following patterns to the repo's `.gitignore` if not already present (control files must not be accidentally committed):
```
overnight-batch-*
overnight-coder-state-*
overnight-coder-parallel-*.json
```

Verify before starting. If any are missing, stop and provide these installation steps:
- Superpowers plugin: install from https://github.com/superpowers-sh/superpowers
- `codex-review-loop` skill: `git clone https://github.com/eishan05/codex-review-loop ~/.claude/skills/codex-review-loop`
- Codex CLI: see https://github.com/openai/codex for install instructions
- GitHub CLI: install from https://cli.github.com, then `gh auth login`

- **macOS or Linux with systemd** (requires `caffeinate` on macOS or `systemd-inhibit` on Linux for sleep prevention — Windows not supported)
- Superpowers plugin (`superpowers:using-git-worktrees`, `superpowers:test-driven-development`, `superpowers:verification-before-completion`)
- `codex-review-loop` skill at `~/.claude/skills/codex-review-loop/` (https://github.com/eishan05/codex-review-loop)
- Codex CLI: `codex --version` must succeed
- GitHub CLI: `gh auth status` must succeed
- GitHub remote: `gh repo view` must succeed (repo must have a GitHub remote configured)

## Process

### Step 0: Resolve Base Branch and Remote

**Announce:** `"[Preflight] Resolving base branch and remote..."`

Resolve and store these two values — used everywhere git and gh commands run:

```bash
# Prefer the upstream remote of the current branch; fall back to first remote
BASE_REMOTE=$(git rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null | cut -d/ -f1)
BASE_REMOTE=${BASE_REMOTE:-$(git remote | head -1)}

# Use GitHub's authoritative default branch; fall back to symbolic ref, then 'main'
BASE_BRANCH=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null)
BASE_BRANCH=${BASE_BRANCH:-$(git symbolic-ref refs/remotes/${BASE_REMOTE}/HEAD 2>/dev/null | sed "s|refs/remotes/${BASE_REMOTE}/||")}
BASE_BRANCH=${BASE_BRANCH:-main}
```

Ensure the local base ref is up to date (do **not** switch the user's checked-out branch — worktrees branch from the fetched remote ref):
```bash
git fetch $BASE_REMOTE $BASE_BRANCH
```

All worktrees are created from `$BASE_REMOTE/$BASE_BRANCH`, so a local checkout of the base branch is unnecessary. If the fetch fails, stop and ask the user to check their network / remote configuration.

Store `base_remote` and `base_branch` in the state file. Use `$BASE_REMOTE` and `$BASE_BRANCH` everywhere `origin` and `main` would otherwise be hardcoded.

### Step 0.5: Collect All User Input

This step frontloads every user question so the rest of the run is fully autonomous. After this step, do not ask any further questions.

**0.5a. Derive BACKLOG_SLUG**

Derive `BACKLOG_SLUG` from the backlog file path: strip the filename's extension, lowercase, replace non-alphanumeric characters with hyphens, collapse multiple hyphens, then append `-` followed by the first 6 characters of the MD5 hash of the absolute path. Use the cross-platform hash command: `if command -v md5sum &>/dev/null; then printf "%s" "<absolute_path>" | md5sum | head -c 6; else printf "%s" "<absolute_path>" | md5 | head -c 6; fi`. This prevents collisions between different backlogs with the same filename (e.g., `TODO.md` at `/proj/foo/TODO.md` → `todo-a3f9c2`).

**0.5b. Check for previous runs**

Look for previous run artifacts:
- **Parallel:** orchestrator manifest `overnight-coder-parallel-{BACKLOG_SLUG}.json` and batch files `overnight-batch-{BACKLOG_SLUG}-*.md`. If batch files exist, read each corresponding group state file to identify incomplete groups.
- **Sequential:** state file `overnight-coder-state-{BACKLOG_SLUG}.json`. If found, read it to get task counts (done, failed, total) and compute whether `backlog_hash` has changed.

**0.5c. Ask all questions in a single prompt**

Use one `AskUserQuestion` with a combined prompt based on what was found:

**If no previous run found:**

> "Two choices before I go autonomous:
> 1. **Mode:** `parallel` or `sequential`?
> 2. **Merge:** `autonomous` (auto-merge PRs) or `review` (leave PRs open)?
>
> Reply like: `parallel, autonomous`"

**If previous sequential run found:**

> "Found a previous sequential run: N/M tasks done, X failed. [⚠️ Backlog file has changed since last run.]
>
> - `resume` — pick up where I left off
> - `fresh parallel, autonomous` or `fresh parallel, review` — start over in parallel
> - `fresh sequential, autonomous` or `fresh sequential, review` — start over sequentially
>
> Reply like: `resume` or `fresh sequential, autonomous`"

**If previous parallel run found with incomplete groups:**

> "Found a previous parallel run. Incomplete groups: {group names}.
>
> - `resume` — pick up where I left off
> - `fresh parallel, autonomous` or `fresh parallel, review` — start over in parallel
> - `fresh sequential, autonomous` or `fresh sequential, review` — start over sequentially
>
> Reply like: `resume` or `fresh parallel, autonomous`"

**Normalization before prompt generation:**

Before choosing which prompt to show, classify the state into exactly one exclusive category. A state file is **resumable** if it has at least one task with status `pending`, `in_progress`, `failed`, or `blocked`. A completed state file (all tasks `done`) is **non-resumable**.

1. **`resumable_sequential_only`** — resumable sequential state file exists; no resumable parallel artifacts
2. **`resumable_parallel_only`** — resumable parallel batch files with incomplete groups exist; no resumable sequential state file
3. **`both_resumable`** — both a resumable sequential state file AND resumable parallel batch files exist
4. **`none`** — no resumable artifacts of either type

**Cleanup during normalization:** Delete all non-resumable artifacts immediately — orphan parallel manifests, all-complete parallel group state files and batch files, and completed sequential state files. This prevents stale files from triggering false detection on future runs.

**Prompt for `none`:** Use the "no previous run" prompt above.

**Prompt for `resumable_sequential_only`:** Use the "previous sequential run" prompt above. Include the backlog-change warning if `backlog_hash` differs.

**Prompt for `resumable_parallel_only`:** Use the "previous parallel run" prompt above.

**Prompt for `both_resumable`:**

> "Found both a previous sequential run (N/M done) and a previous parallel run (incomplete groups: {names}). [⚠️ Backlog file has changed since the sequential run.]
>
> - `resume sequential` or `resume parallel`
> - `fresh parallel, autonomous` or `fresh parallel, review`
> - `fresh sequential, autonomous` or `fresh sequential, review`
>
> Reply like: `resume sequential` or `fresh parallel, autonomous`"

Include the backlog-change warning if the sequential state's `backlog_hash` no longer matches.

**0.5d. Parse and validate response**

Parse the user's response and extract:
- `RESUME` (true/false)
- `MODE` (`parallel` or `sequential`) — explicit from response; on resume, explicit from `resume sequential` / `resume parallel`, or inferred if only one type of resumable state exists
- `MERGE_PREFERENCE` (`autonomous` or `review`) — if resuming, read from existing state file (sequential) or manifest (parallel)

**Validation:** Retry within Step 0.5 if the response is incomplete — do not proceed with missing values. Branch the retry message by case:
- Ambiguous resume (e.g. bare `resume` when both types exist): "Which run? Reply `resume sequential` or `resume parallel`"
- Fresh run missing merge preference (e.g. bare `parallel`): "I need both mode and merge preference — reply like: `parallel, autonomous`"
- Unrecognized input: tailor the example to the current category — for `none` show only fresh-run formats (`parallel, autonomous`); for `both_resumable` show `resume sequential` / `resume parallel`; otherwise show the most relevant example for the category

If `MODE` is sequential: set `STATE_FILE = overnight-coder-state-{BACKLOG_SLUG}.json`.

> **Note:** In parallel mode, if the grouper discovers ordered task groups, `MERGE_PREFERENCE` is overridden to `autonomous` automatically (with a notification). This is the only post-collection adjustment.

Proceed to Parallel Mode Setup (if parallel) or Step 1 (if sequential).

#### Parallel Mode Setup

**0. BACKLOG_SLUG**

`BACKLOG_SLUG` was already derived in Step 0.5a.

**1. Handle previous parallel run (if applicable)**

Previous-run detection and the resume decision were handled in Step 0.5. Use the `RESUME` flag.

- If the manifest exists but **no** batch files exist: the previous run was interrupted between manifest creation and batch file creation. Delete the orphaned manifest and proceed to step 2 as a fresh run.

- **If `RESUME` is true:** Use the `MERGE_PREFERENCE` collected in Step 0.5d (already read from manifest during 0.5d). In each group state file, reset any tasks with status `in_progress` to `pending` (the agent may have been mid-flight when interrupted). Start the sleep inhibitor (same as Step 6.6 — write PID to `/tmp/overnight-coder-caffeinate-{BACKLOG_SLUG}.pid`) before proceeding. Skip to Step 7, re-using existing batch files and state files. Only dispatch implementers for incomplete groups.
- **If `RESUME` is false (fresh start):** Before deleting any state files, read each `overnight-coder-state-{BACKLOG_SLUG}-{group}.json` and collect all task `branch` values that are non-null. For each collected branch, run the same pre-flight cleanup used for sequential retries (remove stale worktree, delete local branch, delete remote branch, close open PR — see Step 5a). Then delete all `overnight-batch-{BACKLOG_SLUG}-*.md` files, all `overnight-coder-state-{BACKLOG_SLUG}-*.json` files, and the `overnight-coder-parallel-{BACKLOG_SLUG}.json` manifest. Proceed to step 2.

**2. Extract task list**

Read the backlog file provided by the user and extract a flat numbered task list using the same parsing rules as Step 1. Present the list and proceed immediately — do not ask for confirmation:

> "I found N tasks:
> 1. Add user authentication
> 2. Fix login redirect bug
> ..."

**3. Invoke grouper subagent**

Read `grouper-prompt.md` (in the same directory as this file). Replace all three placeholders:

| Placeholder | Value |
|---|---|
| `{{TODO_FILE}}` | The backlog file path provided by the user |
| `{{REPO_PATH}}` | Output of `git rev-parse --show-toplevel` |
| `{{CONFIRMED_TASKS}}` | The exact numbered task list extracted in step 2 (verbatim — one task per line, formatted as `1. description`) |

Dispatch a `general-purpose` Agent with the filled prompt.

**4. Announce grouping and proceed**

The grouper returns named groups with `ordered: true/false` per group. Announce the groups to the user but do **not** ask for confirmation — proceed immediately:

> "Parallel groups:
> - **auth** (tasks 1, 3, 5): Authentication and session handling
> - **ui** (tasks 2, 4): Frontend components
> - **api** (tasks 6, 7, 8): REST API endpoints"

If any group has `ordered: true`, append: "⚠️ One or more groups have ordering dependencies — tasks in those groups must build on earlier tasks' merged output."

**5. Apply merge preference and write orchestrator manifest**

Use the `MERGE_PREFERENCE` collected in Step 0.5. However, if any group has `ordered: true` in the grouper output, override `MERGE_PREFERENCE = autonomous` and inform the user: "Merge preference overridden to **autonomous** — one or more task groups have ordering dependencies and require PRs to be merged before dependent tasks can run."

Immediately write `<repo-root>/overnight-coder-parallel-{BACKLOG_SLUG}.json`:

```json
{ "merge_preference": "<autonomous|review>", "backlog_file": "<path>" }
```

This manifest is how the resume path recovers merge preference if interrupted before any worker state file is created.

**6. Write batch files and initialize group state files**

For each group, write its `content:` block to `<repo-root>/overnight-batch-{BACKLOG_SLUG}-{name}.md`:

```
1. Add JWT authentication
3. Implement session refresh
5. Add logout endpoint
```

Then initialize a group state file `overnight-coder-state-{BACKLOG_SLUG}-{name}.json`. If resuming and the file already exists, leave it as-is. For a fresh run, create:

```json
{
  "group": "{name}",
  "ordered": <true|false — from grouper output>,
  "merge_preference": "<MERGE_PREFERENCE>",
  "base_remote": "<BASE_REMOTE>",
  "base_branch": "<BASE_BRANCH>",
  "carry_forward_note": null,
  "first_blocked_at": null,
  "tasks": [
    { "id": <original-id>, "description": "<text>", "status": "pending", "attempts": 0, "branch": null }
  ]
}
```

**`first_blocked_at` lifecycle:**
- Set to the current ISO 8601 timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`) when the first task in a group transitions to `blocked` status **and** `first_blocked_at` is currently null.
- Preserved as-is while any task in the group remains `blocked`.
- Cleared (set to null) whenever all `blocked` tasks in the group are reset to `pending`, marked `failed`, or otherwise leave the `blocked` state.

**6.5. Resolve shared values**

Resolve once — used for every implementer dispatch in step 7:
- `SKILL_DIR`: absolute path to the directory containing SKILL.md
- `WORKTREE_BASE`: (1) existing `.worktrees/` or `worktrees/` dir at repo root, (2) worktree path in CLAUDE.md, (3) default `.worktrees`

**6.6. Sleep announcement**

Run this command to prevent the machine from idle-sleeping and write the PID to a file. The command detects macOS vs Linux automatically. Note: this does **not** prevent lid-close suspend on all platforms — the user-facing message below tells the user to keep the lid open or configure their OS separately.

```bash
if command -v caffeinate &>/dev/null; then
  caffeinate -is &
  echo $! > /tmp/overnight-coder-caffeinate-{BACKLOG_SLUG}.pid
elif command -v systemd-inhibit &>/dev/null; then
  systemd-inhibit --what=idle:sleep:handle-lid-switch --who=overnight-coder --why="Running overnight backlog" sleep infinity &
  echo $! > /tmp/overnight-coder-caffeinate-{BACKLOG_SLUG}.pid
else
  echo "WARNING: No sleep inhibitor found (caffeinate or systemd-inhibit required). Ensure your machine stays awake manually."
  echo "" > /tmp/overnight-coder-caffeinate-{BACKLOG_SLUG}.pid
fi
```

Then print:

```
All set! You can go to sleep now. 🌙 Good night!

I'll work through your N tasks across M parallel groups while you rest.
See you in the morning with a full summary.

⚡ Don't forget to plug your machine into a power source and keep the lid open (or configure lid-close to not suspend) before you go!
```
(Replace N and M with actual task count and group count.)

**7. Round-based parallel implementation**

> **Architecture note:** Claude Code subagents cannot spawn further subagents. All Agent calls must be made from this main orchestrator session. The round-based approach achieves cross-group parallelism while respecting in-group task sequencing.

Each round, pick the next pending task from each group and dispatch all as parallel implementer agents. Repeat until all groups are exhausted.

```
WHILE any group state file has at least one task with status "pending" or "blocked":

  dispatch_list = []

  FOR each group state file:
    IF group has ordered: true AND (any earlier task has status "done" with pr_url != null, OR any earlier task has status "failed", OR any earlier task has status "blocked"):
      For each task with status "done" and pr_url != null:
        Poll: pr_state=$(gh pr view <pr_url> --json state -q '.state')
        IF pr_state == "MERGED":
          Set task.pr_url = null (dependency satisfied).
          git fetch $BASE_REMOTE $BASE_BRANCH
          IF fetch fails AND group has ordered: true:
            Mark all remaining "pending" and "blocked" tasks as "failed" with reason "blocked: base branch fetch failed after task {task.id} merge" and attempts = 2. Write state file. CONTINUE to next group.
          IF fetch fails AND group has ordered: false:
            Set carry_forward_note to "Fetch of $BASE_BRANCH failed after task {task.id} merge; this task may be missing those changes."
          Reset any tasks in this group with status "blocked" and reason containing "blocked: task {task.id}" back to status "pending" with attempts = 0.
          Write state file.
        IF pr_state == "CLOSED":
          Mark task as "failed" with reason "PR was closed without merging".
          Mark all remaining "pending" and "blocked" tasks in this group as "failed" with reason "blocked: upstream task {task.id} PR closed" and attempts = 2.
          Write state file. CONTINUE to next group.
      Re-evaluate: if any earlier task still has status "done" with pr_url != null:
        Mark all remaining "pending" tasks in this group as "blocked" with reason "blocked: task {task.id} PR not yet merged". CONTINUE to next group.
      Re-evaluate: if any earlier task has status "failed" (permanently):
        Mark all remaining "pending" and "blocked" tasks in this group as "failed" with reason "blocked: upstream task {task.id} failed" and attempts = 2.
        Write group state file. CONTINUE to next group.

    task = first task with status "pending"
    IF task exists:
      group_name = group name from state file

      Capture previous_branch = task.branch (may be null on first attempt).
      Compute new branch name:
        overnight/{group_name}-{task.id}-{truncated-slug}  (retries: overnight/{group_name}-{task.id}-r{attempts+1}-{truncated-slug})

      [pre-flight cleanup if task.attempts > 0: using previous_branch — see Step 5a cleanup rules]

      Mark task in_progress, increment attempts, set task.branch to new branch name, write state file.

      Read {SKILL_DIR}/implementer-prompt.md.
      Fill all placeholders (TASK_DESCRIPTION, REPO_PATH, BRANCH_NAME,
        MERGE_PREFERENCE, WORKTREE_BASE, BASE_REMOTE, BASE_BRANCH, CARRY_FORWARD_NOTE).

      dispatch_list.append({ group: group_name, task_id: task.id, prompt: <filled implementer prompt> })
      Clear carry_forward_note in that group's state file (set to null). Write state file.

  IF dispatch_list is empty:
    IF any group has tasks with status "blocked":
      IF blocked tasks have been waiting for more than 15 minutes (track first-blocked timestamp per group in state file):
        For each group with timed-out blocked tasks: mark all "blocked" tasks as "failed" with reason "blocked: timed out waiting for upstream PR to merge (15 min)" and attempts = 2. Write state file.
        CONTINUE (re-evaluate — may now dispatch retries or exit)
      ELSE: sleep 30, then CONTINUE (re-check merges next round)
    ELSE: BREAK

  Dispatch all items in dispatch_list as parallel general-purpose Agent calls in a SINGLE message.

  Wait for all to complete.

  FOR each result:
    Look up the matching (group, task_id) from dispatch_list. Load that group's state file.
    Parse the last line: DONE_MERGED | DONE <url> | FAILED <reason>

    IF result is FAILED <reason>:
      IF task.attempts < 2: reset task status to "pending" (will be retried next round)
      ELSE: mark task "failed" with reason, attempts = 2 (permanently failed)
      Write group state file.

    IF result was DONE_MERGED:
      Mark task "done", set pr_url = null.
      git fetch $BASE_REMOTE $BASE_BRANCH
      If fetch fails AND group has ordered: true:
        Mark all remaining "pending" tasks in that group as "failed" with reason "blocked: base branch refresh failed after task {task_id} merge — dependent tasks would branch from stale code" and attempts = 2.
      If fetch fails AND group has ordered: false:
        Set carry_forward_note to "Previous task was merged but fetch of $BASE_BRANCH failed; this task may be missing those changes."
      Write group state file.

    IF result was DONE <url>:
      Mark task "done", set pr_url = <url>.
      IF group has ordered: true:
        Poll for merge before giving up — the PR may have auto-merge queued:
          pr_state="OPEN"
          FOR i in 1..10:
            pr_state = gh pr view <url> --json state -q '.state'
            IF pr_state == "MERGED": BREAK
            sleep 10
          IF pr_state == "MERGED":
            Set task.pr_url = null (dependency satisfied, treat as DONE_MERGED for this group).
            git fetch $BASE_REMOTE $BASE_BRANCH
            IF fetch fails:
              Mark all remaining "pending" tasks in that group as "failed" with reason "blocked: base branch fetch failed after task {task_id} merge — dependent tasks would branch from stale code" and attempts = 2.
              Write group state file. CONTINUE to next result.
            Reset any tasks in this group with status "blocked" and reason containing "blocked: task {task_id}" back to status "pending" with attempts = 0.
            Clear first_blocked_at if no blocked tasks remain.
          ELSE IF pr_state == "CLOSED":
            Mark task as "failed" with reason "PR was closed without merging".
            Mark all remaining "pending" and "blocked" tasks in this group as "failed" with reason "blocked: upstream task {task_id} PR closed" and attempts = 2.
            Clear first_blocked_at.
          ELSE:
            Mark all remaining "pending" tasks in that group as "blocked" with reason "blocked: task {task_id} not merged (PR: <url>)".
            Set first_blocked_at to current timestamp if null.
      Write group state file.
```

**8. Kill sleep inhibitor and print combined summary**

```bash
_pid=$(cat /tmp/overnight-coder-caffeinate-{BACKLOG_SLUG}.pid 2>/dev/null)
[ -n "$_pid" ] && [ "$_pid" -gt 0 ] 2>/dev/null && kill "$_pid" 2>/dev/null || true
rm -f /tmp/overnight-coder-caffeinate-{BACKLOG_SLUG}.pid
```

Read all group state files and print:

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

**Skip this step if resuming** — the existing state file already has the task list. Instead, announce: "Resuming previous run — N tasks remaining." Then proceed to Step 2.

Read the backlog file provided by the user (accepts any format — markdown checklist, numbered list, prose, GitHub issues export, etc.). Extract a flat ordered list of task descriptions using your judgment.

Present the extracted list and proceed immediately — do not ask for confirmation:

> "I found N tasks:
> 1. Add user authentication
> 2. Fix login redirect bug
> 3. Add payment module"

### Step 2: Check for Previous Run

**Announce:** `"[Step 2/6] Checking for a previous run..."`

Previous-run detection and the resume decision were handled in Step 0.5. Use the `RESUME` flag.

- **If `RESUME` is true:** Skip `done` tasks. Reset `in_progress` → `pending` (agent may have been mid-flight). For `failed` tasks: reset `attempts` to 1 and status to `pending` — they get one fresh attempt; if that attempt also fails (attempts reaches 2), mark permanently `failed`.
- **If `RESUME` is false (or no previous run):** If an old state file exists, read all task `branch` fields from it before overwriting. For each branch, run the same pre-flight cleanup as retries (remove stale worktree, delete local branch, delete remote branch, close open PR). Then overwrite state file and start fresh.

### Step 3: Apply Merge Preference

**Announce:** `"[Step 3/6] Configuring merge preference..."`

**Skip this step if resuming** — read `merge_preference` from the existing state file instead.

Use the `MERGE_PREFERENCE` collected in Step 0.5. No question needed.

### Step 4: Initialize State File

**Announce:** `"[Step 4/6] Initializing state file..."`

**Skip this step if resuming** — the existing state file already has the task list. Only run this step on a fresh start.

Write to `<repo-root>/{STATE_FILE}`:

```json
{
  "backlog_file": "<path provided by user>",
  "backlog_hash": "<first 8 chars of MD5 hash of backlog file contents>",
  "merge_preference": "<autonomous|review>",
  "base_remote": "<e.g. origin>",
  "base_branch": "<e.g. main>",
  "carry_forward_note": null,
  "tasks": [
    { "id": 1, "description": "<task text>", "status": "pending", "attempts": 0, "branch": null }
  ]
}
```

Compute `backlog_hash` using the cross-platform command: `if command -v md5sum &>/dev/null; then md5sum <backlog_file> | head -c 8; else md5 -q <backlog_file> | head -c 8; fi`. The `branch` field is set when task is dispatched (Step 5a) so retries can clean up the previous branch.

### Step 5: Per-Task Loop

**Announce:** `"[Step 5/6] Starting task loop — N tasks queued."`

**Sleep announcement:**

Run this command to prevent your machine from idle-sleeping during the overnight run and write the PID to a file (shell variables do not survive across separate tool calls). Note: this does **not** prevent lid-close suspend on all platforms — the user-facing message below tells the user to keep the lid open or configure their OS separately.

```bash
if command -v caffeinate &>/dev/null; then
  caffeinate -is &
  echo $! > /tmp/overnight-coder-caffeinate-{BACKLOG_SLUG}.pid
elif command -v systemd-inhibit &>/dev/null; then
  systemd-inhibit --what=idle:sleep:handle-lid-switch --who=overnight-coder --why="Running overnight backlog" sleep infinity &
  echo $! > /tmp/overnight-coder-caffeinate-{BACKLOG_SLUG}.pid
else
  echo "WARNING: No sleep inhibitor found (caffeinate or systemd-inhibit required). Ensure your machine stays awake manually."
  echo "" > /tmp/overnight-coder-caffeinate-{BACKLOG_SLUG}.pid
fi
```

Then print:

```
All set! You can go to sleep now. 🌙 Good night!

I'll work through your N tasks while you rest.
See you in the morning with a full summary.

⚡ Don't forget to plug your machine into a power source and keep the lid open (or configure lid-close to not suspend) before you go!
```
(Replace N with the actual pending task count.)

Repeat sequentially for each `pending` task:

**5a. Mark in progress and compute branch name**

**Announce:** `"[Task N/M] Starting: <task description>"`  (N = current task number, M = total tasks)

Before any modification, capture `previous_branch = task.branch` from the current state file (may be null on first attempt).

Increment `attempts`. Compute the new branch name:
- **First attempt (attempts == 1):** `overnight/{task-id}-{slug}` (slug truncated so total ≤ 49 chars)
- **Retry (attempts > 1):** `overnight/{task-id}-r{attempts}-{slug}`

Take the description slug: lowercase, replace all spaces and non-alphanumeric characters with hyphens, collapse multiple hyphens. Including attempt number in retry branches prevents conflicts with leftover remote branches from failed first attempts.

**Pre-flight cleanup (retries only — skip on first attempt):** If `attempts > 1` and `previous_branch` is non-null, a prior attempt may have left a stale worktree or remote branch. Using `previous_branch` (not the new branch name):
1. Check for stale local worktree: `git worktree list` — if any worktree is on `previous_branch`, remove it: `git worktree remove --force <path>`
2. Remove stale local branch: `git branch -D <previous_branch> 2>/dev/null || true`
3. Remove stale remote branch: `git ls-remote --heads $BASE_REMOTE <previous_branch>` — if found, `git push $BASE_REMOTE --delete <previous_branch>`
4. Close any open PR: `gh pr list --head <previous_branch> --json number -q '.[0].number'` — if found, `gh pr close <number>`

After cleanup (or immediately on first attempt), mark task `in_progress`, set `task.branch` to the new branch name, write state file.

Examples (first attempt):
- Task 1: `"Add user auth with JWT"` → `overnight/1-add-user-auth-with-jwt`
- Task 12: `"Fix bug: login redirect (prod)"` → `overnight/12-fix-bug-login-redirect-prod`

Examples (retry):
- Task 1, attempt 2: `"Add user auth with JWT"` → `overnight/1-r2-add-user-auth-with-jwt`

**5b. Build and dispatch implementer**

Locate `implementer-prompt.md`:
- If `SKILL_DIR` is set in your prompt context, read `{SKILL_DIR}/implementer-prompt.md`.
- Otherwise read `implementer-prompt.md` from the same directory as this file.

Replace all placeholders:

Determine `{{REPO_PATH}}` by running `git rev-parse --show-toplevel` in the current working directory.

| Placeholder | Value |
|---|---|
| `{{TASK_DESCRIPTION}}` | The task description text |
| `{{REPO_PATH}}` | Absolute path to the repo root |
| `{{BRANCH_NAME}}` | The computed branch name |
| `{{MERGE_PREFERENCE}}` | `autonomous` or `review` |
| `{{WORKTREE_BASE}}` | Resolve in this priority order: (1) existing `.worktrees/` or `worktrees/` directory at repo root, (2) worktree path in CLAUDE.md, (3) default `.worktrees` |
| `{{BASE_REMOTE}}` | The resolved remote name (e.g. `origin`) |
| `{{BASE_BRANCH}}` | The resolved base branch name (e.g. `main`) |
| `{{CARRY_FORWARD_NOTE}}` | If `carry_forward_note` in state is non-null, inject as `> **Note:** <value>`; otherwise inject as empty string |

Dispatch a `general-purpose` Agent with the filled prompt.

**5c. Handle the result**

The agent's last line will be one of:

- `DONE_MERGED` → mark task `done`, no PR URL
- `DONE <url>` → mark task `done`, save `pr_url: <url>`. **If `merge_preference` is `autonomous`**: the PR was not merged — halt the run. Mark all remaining `pending` tasks as `failed` with reason `"run halted: task N PR not merged (<url>)"` and `attempts = 2`, write state file, and jump to Step 6 immediately. Inform the user: "⚠️ Run halted: task N PR was not merged. Remaining tasks were not started as they may depend on these changes."
- `FAILED <reason>` → if `attempts < 2`, reset to `pending` and go back to 5a (one retry); if `attempts >= 2`, mark `failed` with `reason: <reason>`
- Any other output → treat as `FAILED <raw last line of response>`

Write state file after each result.

**If the result was `DONE_MERGED`** (autonomous merge succeeded), refresh the remote base ref before the next task so subsequent worktrees branch from the updated state:
```bash
git fetch $BASE_REMOTE $BASE_BRANCH
```
If the fetch fails: halt the run. Mark all remaining `pending` tasks as `failed` with reason `"run halted: base branch fetch failed after task N merge — subsequent tasks would branch from stale code"` and `attempts = 2`, write state file, and jump to Step 6. Inform the user: "⚠️ Run halted: could not fetch $BASE_BRANCH after task N merge. Remaining tasks were not started."

In Step 5b, immediately after filling and dispatching the implementer prompt, clear `carry_forward_note` (set to null) in the state file.

**5d. Compact context**

Call `/compact` to compress accumulated context.

Then immediately re-read `{STATE_FILE}` to restore the task list (compaction may clear working memory).

Continue to the next `pending` task.

### Step 6: Final Summary

**Announce:** `"[Step 6/6] All tasks complete! Generating summary..."`

**Kill sleep inhibitor (sequential mode only — parallel mode kills it in Step 8):**
```bash
_pid=$(cat /tmp/overnight-coder-caffeinate-{BACKLOG_SLUG}.pid 2>/dev/null)
[ -n "$_pid" ] && [ "$_pid" -gt 0 ] 2>/dev/null && kill "$_pid" 2>/dev/null || true
rm -f /tmp/overnight-coder-caffeinate-{BACKLOG_SLUG}.pid
```

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
- Skip presenting the extracted task list to the user — always announce what was found before proceeding
- Skip collecting merge preference — must be gathered in Step 0.5 (or read from state file on resume)
- Dispatch implementers in parallel within sequential mode (one at a time — branch conflicts)
- Forget `/compact` between tasks
- Forget to re-read state file after `/compact`
- Start if any prerequisite is missing
