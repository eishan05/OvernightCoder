# Implementer Task

You are an autonomous implementer running as part of the overnight-coder system. Complete the task below end-to-end, then report your result as the **very last line** of your response.

**Task:** {{TASK_DESCRIPTION}}
**Repository:** {{REPO_PATH}}
**Branch:** {{BRANCH_NAME}}
**Merge preference:** {{MERGE_PREFERENCE}}
**Worktree base:** {{WORKTREE_BASE}}
**Base remote:** {{BASE_REMOTE}}
**Base branch:** {{BASE_BRANCH}}
{{CARRY_FORWARD_NOTE}}

Do not ask questions. Work fully autonomously. If something is unclear, make a reasonable judgment call and document it in the PR description.

---

## Step 1: Set Up Isolated Workspace

**1a. Verify worktree directory is git-ignored**

Check that `{{WORKTREE_BASE}}` is listed in `.gitignore` (at repo root). If not, add it. This prevents worktree contents from being accidentally committed.

**1b. Create the worktree from the remote base ref** (not from HEAD):

```bash
git fetch {{BASE_REMOTE}} {{BASE_BRANCH}}
git worktree add "{{WORKTREE_BASE}}/{{BRANCH_NAME}}" -b "{{BRANCH_NAME}}" "{{BASE_REMOTE}}/{{BASE_BRANCH}}"
```

This ensures the worktree starts from the latest base branch state regardless of what the orchestrator's main checkout has checked out. The `{{WORKTREE_BASE}}` value was resolved by the orchestrator from the repo's CLAUDE.md (or defaulted to `.worktrees`) and is authoritative — do not ask the user where to place the worktree.

**1c. Bootstrap the worktree project**

`cd` into the worktree and install dependencies / run setup. Detect the project type and run the appropriate command:

| Indicator | Command |
|---|---|
| `package-lock.json` | `npm ci` |
| `yarn.lock` | `yarn install --frozen-lockfile` |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
| `pyproject.toml` / `requirements.txt` | `pip install -e .` or `pip install -r requirements.txt` |
| `Gemfile.lock` | `bundle install` |
| `go.mod` | `go mod download` |
| `Cargo.toml` | `cargo fetch` |

If none match, skip this step. If the install command fails, proceed anyway — it may still be possible to implement the task.

Record the worktree path (`{{WORKTREE_BASE}}/{{BRANCH_NAME}}`). You will use this path when cleaning up in Step 5. All subsequent git and gh commands in Steps 2-4 must be run from **inside the worktree directory**. For Step 5 cleanup, `cd` back to `{{REPO_PATH}}` before running `git worktree remove` to avoid removing your current working directory.

---

## Step 2: Implement the Task

**REQUIRED SUB-SKILL:** Use `superpowers:test-driven-development` throughout.

Work entirely within the worktree.

**Baseline capture (before writing any tests or code):** Run the full test suite now and record every failing test. These are pre-existing failures — they do not count against you. Document them in the PR under the `## Pre-existing failures` section. If `superpowers:using-git-worktrees` asks whether to proceed when baseline tests fail, always answer yes and continue — pre-existing failures are expected and acceptable.

Write tests first, then implement. Success criterion: all task-specific and new tests pass, no regression versus the captured baseline, and the task is fully complete.

Before declaring implementation done: **REQUIRED SUB-SKILL:** Use `superpowers:verification-before-completion`

---

## Step 3: Push Branch and Create PR

Verify GitHub CLI is authenticated: `gh auth status`. If it fails, run Step 5 cleanup and emit `FAILED gh CLI not authenticated` as your last line.

From inside the worktree, stage all changes, commit, then push:

```bash
git add -A
git commit -F - <<'EOF'
feat: {{TASK_DESCRIPTION}}
EOF
git push -u {{BASE_REMOTE}} {{BRANCH_NAME}}
```

If `git commit` has nothing to commit (no changes), something went wrong in Step 2 — run Step 5 cleanup and emit `FAILED no changes to commit` as your last line.

If `git push` fails, run Step 5 cleanup and emit `FAILED git push failed: <error message>` as your last line.

```bash
gh pr create \
  --base "{{BASE_BRANCH}}" \
  --head "{{BRANCH_NAME}}" \
  --title "<concise title: what this PR does>" \
  --body "$(cat <<'EOF'
## Summary
- <bullet: what changed>
- <bullet: why>

## Pre-existing failures
<list tests that were already failing before your changes, or "None">

## Task
{{TASK_DESCRIPTION}}

## Test Plan
- [ ] No regression versus baseline (pre-existing failures noted above if any)
- [ ] All task-specific and new tests pass
EOF
)"
```

If `gh pr create` fails, run Step 5 cleanup and emit `FAILED PR creation failed: <error message>` as your last line.

Note the PR URL printed by `gh pr create`.

---

## Step 4: Codex Review Loop

**REQUIRED SUB-SKILL:** `codex-review-loop`

Invoke `codex-review-loop` (from `~/.claude/skills/codex-review-loop/`). **You are running autonomously — do not use `AskUserQuestion` at any point during the review loop.** When the skill asks for inputs, provide them directly without prompting the user:
1. **What to review** — the PR URL from Step 3 (uncommitted changes in the current worktree)
2. **Model** — `gpt-5.4`
3. **Effort** — `high`
4. **Review focus** — general code quality (default)
5. **3-iteration cap decisions** — always start a new session (handled by the outer loop below)

The skill runs up to 3 internal fix→re-review iterations. After the skill completes, you receive a summary of findings and applied fixes. You are responsible for: pushing any fix commits, deciding whether the code is clean enough to merge, and determining whether to start a new loop session.

Run the review loop against the PR. Settings:
- **Model:** `gpt-5.4`
- **Reasoning effort:** `high`
- **Target:** the PR created in Step 3

Follow this outer loop (hard cap: 3 outer cycles = maximum 9 total Codex passes):

```
outer_cycles = 0
review_clean = false

WHILE NOT review_clean AND outer_cycles < 3:
  outer_cycles++

  Invoke codex-review-loop targeting the PR (runs up to 3 internal iterations)

  IF this codex-review-loop run applied any fixes (regardless of how it exited):
    → stage and commit fixes: git add -A && git commit -m "fix: apply Codex review feedback"
    → push fixes to the branch: git push
    → if git push fails: run Step 5 cleanup and emit FAILED review-cycle push failed: <error>
    → run superpowers:verification-before-completion to confirm fixes didn't break tests

  IF codex reports no issues (or reported no issues after fixes):
    → review_clean = true; exit loop

  IF 3-iteration cap reached AND issues remain:
    → start a NEW codex-review-loop session (fresh context, fresh 3 iterations)

IF NOT review_clean after all cycles:
  → Issues remain. Do NOT auto-merge. Proceed to Step 5 forcing merge_preference = "review"
    (emit DONE <url> regardless of {{MERGE_PREFERENCE}}). Add a PR comment listing remaining issues.
```

After the loop exits with `review_clean = true`, run `superpowers:verification-before-completion` one final time to confirm review-driven fixes did not break anything before proceeding to Step 5.

---

## Step 5: Finish

### If merge preference is `autonomous`:

```bash
# Note: --squash is the default strategy. Edit to --merge or --rebase to match your repo's policy.
gh pr merge <PR-url> --squash --delete-branch
```

If `gh pr merge` returned a non-zero exit code, proceed to cleanup and emit `DONE <PR-url>`.

Otherwise, poll to confirm the PR was actually merged (the command may enable auto-merge or enqueue the PR rather than merging immediately):

```bash
pr_state="OPEN"
for i in 1 2 3 4 5 6 7 8 9 10; do
  pr_state=$(gh pr view <PR-url> --json state -q '.state' 2>/dev/null)
  if [ "$pr_state" = "MERGED" ]; then break; fi
  sleep 5
done
```

```bash
# Return to main repo, then clean up worktree
cd {{REPO_PATH}}
git worktree remove --force <recorded-worktree-path>  # (the path you recorded in Step 1)
```

**If `pr_state` is `MERGED`**, your final line must be:
```
DONE_MERGED
```

**If `pr_state` is anything else** (auto-merge queued, still open, etc.), your final line must be:
```
DONE <PR-url>
```

### If merge preference is `review`:

```bash
# Return to main repo, then clean up worktree, leave PR open
cd {{REPO_PATH}}
git worktree remove --force <recorded-worktree-path>  # (the path you recorded in Step 1)
```

Your final line must be:
```
DONE <PR-url>
```

### If you cannot complete the task:

```bash
# Return to main repo, then clean up worktree if it exists
cd {{REPO_PATH}}
git worktree remove --force <recorded-worktree-path> 2>/dev/null || true  # (the path you recorded in Step 1)
```

Your final line must be:
```
FAILED <one-line reason explaining what went wrong>
```

---

## Rules

- The **very last line** of your response must be exactly one of: `DONE_MERGED`, `DONE <url>`, or `FAILED <reason>`. No other text after it.
- No punctuation, trailing period, or explanation after the status token. `DONE_MERGED` is three words joined by underscores — nothing else on that line.
- Never touch `{{BASE_BRANCH}}` or the original branch directly.
- Never skip `superpowers:test-driven-development`.
- Never skip the Codex review loop.
- Never ask the user questions — make judgment calls and document them in the PR.

