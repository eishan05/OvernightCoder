# overnight-coder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the `overnight-coder` Claude Code skill — a thin orchestrator that reads a backlog file, dispatches implementer subagents for each task sequentially, manages a state file for resumability, compacts context between tasks, and surfaces a final summary.

**Architecture:** Three files: `README.md` (install instructions), `skills/overnight-coder/SKILL.md` (orchestrator logic), `skills/overnight-coder/implementer-prompt.md` (template injected into each implementer subagent). No code — all documentation. Verification is reading the output against the spec.

**Tech Stack:** Markdown, YAML frontmatter, Claude Code skill format, bash/gh CLI snippets referenced in docs.

---

## File Structure

| File | Responsibility |
|---|---|
| `README.md` | Prerequisites, install instructions, usage, configuration |
| `skills/overnight-coder/SKILL.md` | Orchestrator: parse backlog, manage state, dispatch implementers, compact context |
| `skills/overnight-coder/implementer-prompt.md` | Template: end-to-end implementer lifecycle with placeholder variables |

---

### Task 1: Write README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README.md with the exact content below**

```markdown
# overnight-coder

An overnight autonomous coding skill for Claude Code. Give it your backlog — it implements every task while you sleep.

For each task, overnight-coder creates an isolated branch, implements the task using TDD, gets the code reviewed by Codex, and either merges the PR or leaves it open for you to review.

## Prerequisites

Install all of these before using overnight-coder:

### 1. Superpowers Plugin

Install from the Claude Code plugin marketplace or follow instructions at https://superpowers.so

Verify the following skills are available in your Claude Code session:
- `superpowers:using-git-worktrees`
- `superpowers:test-driven-development`
- `superpowers:verification-before-completion`

### 2. codex-review-loop Skill

```bash
git clone https://github.com/eishan05/codex-review-loop ~/.claude/skills/codex-review-loop
```

### 3. Codex CLI

Install from https://github.com/openai/codex

Verify:
```bash
codex --version
```

### 4. overnight-coder Skill (this repo)

```bash
cp -r skills/overnight-coder ~/.claude/skills/overnight-coder
```

Or if cloning fresh:
```bash
git clone https://github.com/eishan05/overnight-coder
cp -r overnight-coder/skills/overnight-coder ~/.claude/skills/overnight-coder
```

## Usage

1. Create a backlog file in your project (any format works):

```markdown
- [ ] Add user authentication with JWT tokens
- [ ] Fix the login redirect bug
- [ ] Add payment module with Stripe
```

2. Open Claude Code in your project directory and invoke the skill:

```
Use the overnight-coder skill with TODO.md
```

3. Answer two questions at startup:
   - **Merge preference:** `autonomous` (auto-merge PRs) or `review` (leave PRs open for you to review)
   - If a previous run exists: resume or start fresh

4. Let it run overnight. Check the final summary in the morning.

## Configuration

Codex model and reasoning effort are set in `skills/overnight-coder/implementer-prompt.md`.

Defaults: model `gpt-5.4`, reasoning effort `high`.

To change them, edit the relevant lines in `implementer-prompt.md` before invoking the skill.

## State File

overnight-coder saves progress to `overnight-coder-state.json` in your repo root. This file enables resuming interrupted runs.

To start completely fresh, delete it:
```bash
rm overnight-coder-state.json
```

To prevent it from being committed:
```bash
echo "overnight-coder-state.json" >> .gitignore
```

## How It Works

1. Parses your backlog into a flat task list (confirms with you before starting)
2. Asks your merge preference once
3. For each task sequentially:
   - Creates an isolated git worktree + branch (`overnight/<task-slug>`)
   - Implements using TDD (`superpowers:test-driven-development`)
   - Pushes branch and creates a GitHub PR
   - Runs Codex review loop until clean (model `gpt-5.4`, effort `high`, max 9 passes)
   - Merges or leaves PR open based on your preference
4. If a task fails, retries once with a fresh agent. If it fails again, logs the failure and moves on.
5. Compacts context between tasks so it can run overnight without hitting context limits
6. Prints a final summary of done/failed tasks and PR URLs

## License

MIT
```

- [ ] **Step 2: Verify README.md covers all dependencies from the spec**

Check:
- Superpowers plugin ✓
- codex-review-loop from https://github.com/eishan05/codex-review-loop ✓
- Codex CLI ✓
- Model/effort configuration ✓
- State file explanation ✓

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "feat: add README with install instructions and usage"
```

---

### Task 2: Write skills/overnight-coder/SKILL.md

**Files:**
- Create: `skills/overnight-coder/SKILL.md`

- [ ] **Step 1: Write SKILL.md with the exact content below**

```markdown
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

### Step 2: Ask Merge Preference

Ask via `AskUserQuestion`:

> "Merge preference: **autonomous** (auto-merge PRs to main after Codex review) or **review** (leave PRs open for you to review)?"

Store as `autonomous` or `review`.

### Step 3: Check for Previous Run

Look for `overnight-coder-state.json` in the repo root.

If found, ask:

> "Found previous run: N/M tasks complete, X failed. Resume? (y/n)"

- **Yes:** Skip `done` tasks. Reset `in_progress` → `pending` (agent may have been mid-flight). Give `failed` tasks one fresh attempt — if that attempt also fails, mark permanently `failed`.
- **No:** Overwrite state file, start fresh.

### Step 4: Initialize State File

Write to `<repo-root>/overnight-coder-state.json`:

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

Compute branch name: take the task description, lowercase it, replace all spaces and non-alphanumeric characters with hyphens, collapse multiple hyphens into one, truncate to 40 characters, prefix with `overnight/`.

Examples:
- `"Add user auth with JWT"` → `overnight/add-user-auth-with-jwt`
- `"Fix bug: login redirect (prod)"` → `overnight/fix-bug-login-redirect-prod`

**5b. Build and dispatch implementer**

Read `implementer-prompt.md` (in the same directory as this file). Replace all four placeholders:

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

Write state file after each result.

**5d. Compact context**

Call `/compact` to compress accumulated context.

Then immediately re-read `overnight-coder-state.json` to restore the task list (compaction may clear working memory).

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

## Red Flags

**Never:**
- Proceed without user confirming the extracted task list
- Skip asking merge preference
- Dispatch implementers in parallel (sequential only — branch conflicts)
- Forget `/compact` between tasks
- Forget to re-read state file after `/compact`
- Start if any prerequisite is missing
```

- [ ] **Step 2: Verify SKILL.md against spec**

Check each spec requirement has a matching section:
- Flexible backlog parsing ✓ (Step 1: "accepts any format")
- Merge preference question ✓ (Step 2)
- Resume logic including `in_progress` → `pending` reset ✓ (Step 3)
- State file with all fields ✓ (Step 4)
- Branch slug format (lowercase, hyphens, 40-char truncate) ✓ (Step 5a)
- Retry once on FAILED, permanently fail on second failure ✓ (Step 5c)
- `/compact` + re-read state file ✓ (Step 5d)
- Final summary format ✓ (Step 6)
- Prerequisites check ✓

- [ ] **Step 3: Commit**

```bash
git add skills/overnight-coder/SKILL.md
git commit -m "feat: add overnight-coder orchestrator SKILL.md"
```

---

### Task 3: Write skills/overnight-coder/implementer-prompt.md

**Files:**
- Create: `skills/overnight-coder/implementer-prompt.md`

- [ ] **Step 1: Write implementer-prompt.md with the exact content below**

```markdown
# Implementer Task

You are an autonomous implementer running as part of the overnight-coder system. Complete the task below end-to-end, then report your result as the **very last line** of your response.

**Task:** {{TASK_DESCRIPTION}}
**Repository:** {{REPO_PATH}}
**Branch:** {{BRANCH_NAME}}
**Merge preference:** {{MERGE_PREFERENCE}}

Do not ask questions. Work fully autonomously. If something is unclear, make a reasonable judgment call and document it in the PR description.

---

## Step 1: Set Up Isolated Workspace

**REQUIRED SUB-SKILL:** Use `superpowers:using-git-worktrees`

Create an isolated worktree on branch `{{BRANCH_NAME}}`. Do not modify the current local branch or main. The worktree should use `.worktrees/` or wherever the project convention is.

---

## Step 2: Implement the Task

**REQUIRED SUB-SKILL:** Use `superpowers:test-driven-development` throughout.

Work entirely within the worktree. Write tests first, then implement. Continue until all tests pass and the task is fully complete.

Before declaring implementation done: **REQUIRED SUB-SKILL:** Use `superpowers:verification-before-completion`

---

## Step 3: Push Branch and Create PR

From inside the worktree:

```bash
git push -u origin {{BRANCH_NAME}}

gh pr create \
  --title "<concise title: what this PR does>" \
  --body "$(cat <<'EOF'
## Summary
- <bullet: what changed>
- <bullet: why>

## Task
{{TASK_DESCRIPTION}}

## Test Plan
- [ ] All existing tests pass
- [ ] New tests cover new functionality
EOF
)"
```

Note the PR URL printed by `gh pr create`.

---

## Step 4: Codex Review Loop

**REQUIRED SKILL:** `codex-review-loop`

Run the review loop against the PR. Settings:
- **Model:** `gpt-5.4`
- **Reasoning effort:** `high`
- **Target:** the PR created in Step 3

Follow this outer loop (hard cap: 3 outer cycles = maximum 9 total Codex passes):

```
outer_cycles = 0

WHILE not clean AND outer_cycles < 3:
  outer_cycles++

  Invoke codex-review-loop targeting the PR (runs up to 3 internal iterations)

  IF codex reports no issues:
    → exit — code is clean

  IF 3-iteration cap reached AND you applied fixes this run:
    → push fixes to the branch: git push
    → start a NEW codex-review-loop session (fresh context, fresh 3 iterations)

  IF 3-iteration cap reached AND you judge remaining issues are
     already addressed or not worth fixing:
    → exit — declare clean

IF outer_cycles == 3 with issues still open:
  → exit — hard cap reached
```

After every round of fixes, push commits so Codex reviews the latest code:

```bash
git add -A
git commit -m "fix: address codex review feedback"
git push
```

---

## Step 5: Finish

### If merge preference is `autonomous`:

```bash
# Merge the PR
gh pr merge {{BRANCH_NAME}} --merge --delete-branch

# Clean up worktree (replace <worktree-path> with actual path)
git worktree remove <worktree-path>
```

Your final line must be:
```
DONE_MERGED
```

### If merge preference is `review`:

```bash
# Clean up worktree, leave PR open
git worktree remove <worktree-path>
```

Your final line must be:
```
DONE <PR-url>
```

### If you cannot complete the task:

```bash
# Clean up worktree if it exists
git worktree remove <worktree-path> 2>/dev/null || true
```

Your final line must be:
```
FAILED <one-line reason explaining what went wrong>
```

---

## Rules

- The **very last line** of your response must be exactly one of: `DONE_MERGED`, `DONE <url>`, or `FAILED <reason>`. No other text after it.
- Never touch `main` or the original branch directly.
- Never skip `superpowers:test-driven-development`.
- Never skip the Codex review loop.
- Never ask the user questions — make judgment calls and document them in the PR.
```

- [ ] **Step 2: Verify implementer-prompt.md against spec**

Check each spec requirement:
- All four placeholders present: `{{TASK_DESCRIPTION}}`, `{{REPO_PATH}}`, `{{BRANCH_NAME}}`, `{{MERGE_PREFERENCE}}` ✓
- `superpowers:using-git-worktrees` in Step 1 ✓
- `superpowers:test-driven-development` in Step 2 ✓
- `superpowers:verification-before-completion` in Step 2 ✓
- PR creation with `gh pr create` in Step 3 ✓
- Codex model `gpt-5.4`, effort `high` in Step 4 ✓
- Outer loop with 3-cycle hard cap in Step 4 ✓
- Push fixes after each inner codex-review-loop in Step 4 ✓
- Merge + worktree cleanup for `autonomous` in Step 5 ✓
- Worktree cleanup only for `review` in Step 5 ✓
- Status codes `DONE_MERGED`, `DONE <url>`, `FAILED <reason>` in Step 5 ✓
- "No questions" rule ✓

- [ ] **Step 3: Commit**

```bash
git add skills/overnight-coder/implementer-prompt.md
git commit -m "feat: add implementer-prompt.md template"
```

---

### Task 4: Final Review and Tag

**Files:** No new files. Review existing.

- [ ] **Step 1: Read all three files and verify cross-references are consistent**

Read README.md, SKILL.md, and implementer-prompt.md. Verify:
- README install path matches the `skills/overnight-coder/` directory structure
- SKILL.md `implementer-prompt.md` reference ("same directory as this file") is correct
- Model `gpt-5.4` and effort `high` are set only in implementer-prompt.md (SKILL.md defers to the template — this is correct per spec)
- All four placeholder variables in SKILL.md Step 5b match the four in implementer-prompt.md

- [ ] **Step 2: Verify spec coverage**

Walk through each spec section and confirm coverage:
- Dependencies table → README Prerequisites ✓
- Orchestrator startup (parse, confirm, merge preference, resume) → SKILL.md Steps 1-4 ✓
- State file JSON shape → SKILL.md Step 4 ✓
- Per-task loop (in_progress, attempts, branch slug, dispatch, retry logic) → SKILL.md Step 5 ✓
- `/compact` + re-read → SKILL.md Step 5d ✓
- Final summary format → SKILL.md Step 6 ✓
- Implementer lifecycle steps 1-5 → implementer-prompt.md ✓
- Codex outer loop hard cap (3 cycles) → implementer-prompt.md Step 4 ✓
- Status codes → implementer-prompt.md Step 5 ✓

- [ ] **Step 3: Final commit (only if review found issues that were fixed)**

```bash
git diff --quiet && echo "nothing to commit" || git commit -am "fix: address final review findings in overnight-coder skill

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```
