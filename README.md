# overnight-coder

An overnight autonomous coding skill for Claude Code. Give it your backlog — it implements every task while you sleep.

For each task, overnight-coder creates an isolated branch, implements the task using TDD, gets the code reviewed by Codex, and either merges the PR or leaves it open for you to review.

## Prerequisites

Install all of these before using overnight-coder:

### 1. Superpowers Plugin

Follow the install instructions at https://superpowers.so

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

### 4. GitHub CLI

Install from https://cli.github.com and authenticate:

```bash
gh auth login
```

Verify:
```bash
gh auth status
```

### 5. overnight-coder Skill (this repo)

From the repo root:
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

> **Note:** Your project must have a GitHub remote configured (`git remote -v` should show a github.com URL).

## Configuration

Codex model and reasoning effort are set in `~/.claude/skills/overnight-coder/implementer-prompt.md` (the installed copy).

Defaults: model `gpt-5.4`, reasoning effort `high`.

To change them, edit the `Model:` and `Reasoning effort:` lines in the `## Step 4: Codex Review Loop` section of `~/.claude/skills/overnight-coder/implementer-prompt.md` before invoking the skill.

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
   - Runs Codex review loop until clean (model `gpt-5.4`, effort `high`, max 9 passes = 3 outer cycles × 3 inner iterations)
   - Merges or leaves PR open based on your preference
4. If a task fails, retries once with a fresh agent. If it fails again, logs the failure and moves on.
5. Compacts context between tasks so it can run overnight without hitting context limits
6. Prints a final summary of done/failed tasks and PR URLs

## License

MIT
