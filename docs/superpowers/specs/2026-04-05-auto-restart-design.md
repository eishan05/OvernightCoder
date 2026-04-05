# Auto-Restart on Usage Limits

## Problem

When Claude Code hits API usage limits on the Max plan during an overnight-coder run, the CLI shows an interactive menu requiring the user to manually select "Wait for limits reset" and then type "continue" after the limit resets. The user is asleep and cannot interact, so the run stalls.

## Solution

A two-part solution:

1. **`overnight-runner.sh`** — A bash wrapper script that runs Claude Code in `-p` (print/headless) mode and automatically restarts it after usage limit exits, leveraging the skill's existing state file resume mechanism.
2. **SKILL.md auto-resume sentinel** — A `.overnight-coder-auto-resume` file that tells the skill to skip interactive resume questions on restart.

## Design

### Wrapper Script (`overnight-runner.sh`)

**Location:** Repository root.

**Usage:**
```bash
./overnight-runner.sh <backlog-file> [--cooldown <minutes>] [--max-restarts <N>] [-- <extra claude args>]
```

**Defaults:**
- `--cooldown 60` (Max plan limits typically reset in 1-2 hours)
- `--max-restarts 10`

**Flow:**

1. Validate arguments and check `claude --version` exists.
2. Launch Claude Code: `claude -p "Use the overnight-coder skill with <file>" --yes`
3. Capture session ID from `~/.claude/projects/` after launch.
4. On exit, check state files for pending/in_progress/blocked tasks.
5. If all tasks done or permanently failed, exit successfully.
6. If tasks remain: wait `--cooldown` minutes, create `.overnight-coder-auto-resume`, attempt session resume with `claude -r <session_id> -p "continue working on the overnight-coder backlog" --yes`. If session resume fails, fall back to fresh invocation.
7. Repeat until complete or `--max-restarts` reached.

**State file inspection:** Uses `python3` (available on macOS and most Linux) to parse JSON state files and count tasks with status `pending`, `in_progress`, or `blocked`.

**Logging:** All output tee'd to `overnight-runner.log` with timestamps.

**Sleep prevention:** The skill already runs `caffeinate`/`systemd-inhibit`. The wrapper does not duplicate this — it relies on the skill's own sleep prevention which persists via PID file across restarts.

### SKILL.md Auto-Resume Sentinel

**Sentinel file:** `.overnight-coder-auto-resume` in the repo root.

**Changes to SKILL.md:**

1. **Prerequisites:** Add `.overnight-coder-auto-resume` to the `.gitignore` patterns list.

2. **Step 2 (Sequential — Check for Previous Run):** Before asking "Resume? (y/n)", check if `.overnight-coder-auto-resume` exists. If so, delete it, skip the question, and proceed as "Yes". Also skip Step 3 (merge preference is already in the state file from the previous run).

3. **Parallel Mode Setup Step 1:** Same pattern — if sentinel exists, delete it, auto-resume incomplete groups, read merge preference from the manifest.

4. **Step 0.5 (Parallel Mode Check):** If sentinel exists and a previous run's state file/manifest exists, infer the mode (sequential vs parallel) from which state files are present rather than asking.

### README Update

Add an "Auto-Restart on Usage Limits" section after "Resuming a Stopped Run" covering usage, configuration, and how it works.

## What We're NOT Doing

- No `expect` or PTY automation (fragile, depends on CLI output format)
- No Agent SDK rewrite (future evolution)
- No changes to implementer-prompt.md or grouper-prompt.md
- No changes to core task loop logic
