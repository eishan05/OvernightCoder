#!/usr/bin/env bash
# overnight-runner.sh — Auto-restart wrapper for overnight-coder
#
# Runs Claude Code with the overnight-coder skill in headless mode (-p).
# When Claude exits (e.g., due to usage limits), checks if tasks remain,
# waits a cooldown period, then restarts — leveraging the skill's built-in
# state file resume mechanism.
#
# Usage:
#   ./overnight-runner.sh <backlog-file> [options] [-- <extra claude args>]
#
# Options:
#   --mode <sequential|parallel>   Execution mode (default: sequential)
#   --merge <autonomous|review>    Merge preference (default: autonomous)
#   --cooldown <minutes>           Wait between restarts (default: 60)
#   --max-restarts <N>             Safety cap on restart attempts (default: 10)
#
# Examples:
#   ./overnight-runner.sh TODO.md
#   ./overnight-runner.sh TODO.md --mode parallel --merge review
#   ./overnight-runner.sh TODO.md --cooldown 90 --max-restarts 5
#   ./overnight-runner.sh TODO.md -- --model claude-sonnet-4-6

# No set -e: the main loop handles Claude exit codes explicitly.
set -uo pipefail

# ── Argument parsing ────────────────────────────────────────────────────

BACKLOG_FILE=""
MODE="sequential"
MERGE_PREFERENCE="autonomous"
COOLDOWN_MINUTES=60
MAX_RESTARTS=10
EXTRA_CLAUDE_ARGS=()

usage() {
  echo "Usage: overnight-runner.sh <backlog-file> [--mode sequential|parallel] [--merge autonomous|review] [--cooldown MINUTES] [--max-restarts N] [-- <claude args>]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || { echo "Error: --mode requires a value" >&2; usage; exit 1; }
      MODE="$2"
      if [[ "$MODE" != "sequential" && "$MODE" != "parallel" ]]; then
        echo "Error: --mode must be 'sequential' or 'parallel', got '$MODE'" >&2
        exit 1
      fi
      shift 2
      ;;
    --merge)
      [[ $# -ge 2 ]] || { echo "Error: --merge requires a value" >&2; usage; exit 1; }
      MERGE_PREFERENCE="$2"
      if [[ "$MERGE_PREFERENCE" != "autonomous" && "$MERGE_PREFERENCE" != "review" ]]; then
        echo "Error: --merge must be 'autonomous' or 'review', got '$MERGE_PREFERENCE'" >&2
        exit 1
      fi
      shift 2
      ;;
    --cooldown)
      [[ $# -ge 2 ]] || { echo "Error: --cooldown requires a value" >&2; usage; exit 1; }
      COOLDOWN_MINUTES="$2"
      if ! [[ "$COOLDOWN_MINUTES" =~ ^[0-9]+$ ]]; then
        echo "Error: --cooldown must be a positive integer, got '$COOLDOWN_MINUTES'" >&2
        exit 1
      fi
      shift 2
      ;;
    --max-restarts)
      [[ $# -ge 2 ]] || { echo "Error: --max-restarts requires a value" >&2; usage; exit 1; }
      MAX_RESTARTS="$2"
      if ! [[ "$MAX_RESTARTS" =~ ^[0-9]+$ ]]; then
        echo "Error: --max-restarts must be a positive integer, got '$MAX_RESTARTS'" >&2
        exit 1
      fi
      shift 2
      ;;
    --)
      shift
      EXTRA_CLAUDE_ARGS=("$@")
      break
      ;;
    -*)
      echo "Error: Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "$BACKLOG_FILE" ]]; then
        BACKLOG_FILE="$1"
      else
        echo "Error: Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$BACKLOG_FILE" ]]; then
  usage
  exit 1
fi

if [[ ! -f "$BACKLOG_FILE" ]]; then
  echo "Error: backlog file not found: $BACKLOG_FILE" >&2
  exit 1
fi

# ── Preflight checks ───────────────────────────────────────────────────

if ! command -v claude &>/dev/null; then
  echo "Error: 'claude' CLI not found in PATH" >&2
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "Error: 'python3' not found in PATH (needed to inspect state files)" >&2
  exit 1
fi

# ── Derived values ──────────────────────────────────────────────────────

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOG_FILE="${REPO_ROOT}/overnight-runner.log"
RESTART_COUNT=0

# Compute BACKLOG_SLUG the same way the skill does, so we can scope state file checks.
BACKLOG_ABS="$(cd "$(dirname "$BACKLOG_FILE")" && pwd)/$(basename "$BACKLOG_FILE")"
BACKLOG_BASENAME="$(basename "$BACKLOG_FILE")"
BACKLOG_SLUG=$(echo "${BACKLOG_BASENAME%.*}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')
if command -v md5sum &>/dev/null; then
  HASH=$(printf "%s" "$BACKLOG_ABS" | md5sum | head -c 6)
else
  HASH=$(printf "%s" "$BACKLOG_ABS" | md5 | head -c 6)
fi
BACKLOG_SLUG="${BACKLOG_SLUG}-${HASH}"

SENTINEL_FILE="${REPO_ROOT}/.overnight-coder-auto-resume"

# ── Helpers ─────────────────────────────────────────────────────────────

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Check if any run artifacts exist for this backlog.
run_artifacts_exist() {
  for sf in "${REPO_ROOT}"/overnight-coder-state-"${BACKLOG_SLUG}"*.json; do
    [[ -f "$sf" ]] && return 0
  done
  [[ -f "${REPO_ROOT}/overnight-coder-parallel-${BACKLOG_SLUG}.json" ]] && return 0
  for bf in "${REPO_ROOT}"/overnight-batch-"${BACKLOG_SLUG}"-*.md; do
    [[ -f "$bf" ]] && return 0
  done
  return 1
}

# Check state files scoped to this backlog for remaining work.
# Returns 0 if resumable tasks remain, 1 if no resumable tasks.
# Sequential: any non-done task is resumable (skill resets all failed on resume).
# Parallel: only pending/in_progress/blocked are resumable (failed stays terminal).
has_pending_tasks() {
  if ! run_artifacts_exist; then
    return 1  # No artifacts at all = skill never initialized; retrying won't help
  fi

  # If parallel artifacts exist but no group state files, setup was in progress.
  local has_state_files=false
  for sf in "${REPO_ROOT}"/overnight-coder-state-"${BACKLOG_SLUG}"*.json; do
    [[ -f "$sf" ]] && { has_state_files=true; break; }
  done
  if ! $has_state_files; then
    return 0  # Manifest/batch exist but no group states — setup in progress
  fi

  for sf in "${REPO_ROOT}"/overnight-coder-state-"${BACKLOG_SLUG}"*.json; do
    [[ -f "$sf" ]] || continue

    local pending
    pending=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    tasks = data.get('tasks', [])
    is_parallel = 'group' in data  # parallel group state files have a 'group' key

    if is_parallel:
        # Parallel resume only resets in_progress->pending; failed tasks stay failed.
        # Only count tasks the parallel executor will actually process.
        unfinished = [t for t in tasks if t.get('status') in ('pending', 'in_progress', 'blocked')]
    else:
        # Sequential resume resets ALL failed tasks back to pending.
        # Any non-done task is potentially resumable.
        unfinished = [t for t in tasks if t.get('status') != 'done']

    print(len(unfinished))
except Exception:
    # Corrupted/truncated JSON — assume tasks remain so we retry
    print('1')
" "$sf" 2>/dev/null)

    if [[ "$pending" =~ ^[0-9]+$ ]] && [[ "$pending" -gt 0 ]]; then
      return 0
    fi
  done

  return 1
}

# Write the auto-resume sentinel. Always includes mode and merge_preference
# so the skill can proceed without asking — whether this is a first run or restart.
write_sentinel() {
  python3 -c "
import json, sys
data = {
    'backlog_file': sys.argv[1],
    'mode': sys.argv[2],
    'merge_preference': sys.argv[3]
}
with open(sys.argv[4], 'w') as f:
    json.dump(data, f)
" "$BACKLOG_FILE" "$MODE" "$MERGE_PREFERENCE" "$SENTINEL_FILE"
}

# Run Claude Code. Returns its exit code without killing the script.
run_claude() {
  local prompt="$1"
  local exit_code

  if [[ ${#EXTRA_CLAUDE_ARGS[@]} -gt 0 ]]; then
    claude -p "$prompt" --yes "${EXTRA_CLAUDE_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE" || true
  else
    claude -p "$prompt" --yes 2>&1 | tee -a "$LOG_FILE" || true
  fi
  exit_code=${PIPESTATUS[0]}

  return "$exit_code"
}

# ── Main loop ───────────────────────────────────────────────────────────

log "============================================"
log "overnight-runner started"
log "  Backlog:       $BACKLOG_FILE"
log "  Backlog slug:  $BACKLOG_SLUG"
log "  Mode:          $MODE"
log "  Merge:         $MERGE_PREFERENCE"
log "  Cooldown:      ${COOLDOWN_MINUTES}m"
log "  Max restarts:  $MAX_RESTARTS"
log "  Repo root:     $REPO_ROOT"
if [[ ${#EXTRA_CLAUDE_ARGS[@]} -gt 0 ]]; then
  log "  Extra args:    ${EXTRA_CLAUDE_ARGS[*]}"
fi
log "============================================"

# Write sentinel with preferences (used by skill to skip AskUserQuestion in -p mode)
write_sentinel
log "Created sentinel (mode=$MODE, merge=$MERGE_PREFERENCE)."

PROMPT="Use the overnight-coder skill with $BACKLOG_FILE"
log "Starting initial run..."
run_claude "$PROMPT"
LAST_EXIT=$?
log "Initial run exited with code $LAST_EXIT"

# If the skill never created state files, it failed during setup — don't retry.
if ! run_artifacts_exist; then
  log "No state files found after initial run. The skill failed to initialize."
  log "Check the log output above for errors (missing prerequisites, bad backlog file, etc.)."
  rm -f "$SENTINEL_FILE"
  exit 1
fi

# Restart loop — only entered if state files exist and have pending tasks
while has_pending_tasks; do
  RESTART_COUNT=$((RESTART_COUNT + 1))

  if [[ $RESTART_COUNT -gt $MAX_RESTARTS ]]; then
    log "Max restarts ($MAX_RESTARTS) reached. Exiting."
    log "Run './overnight-runner.sh $BACKLOG_FILE' again to resume remaining tasks."
    rm -f "$SENTINEL_FILE"
    exit 1
  fi

  log "Tasks still pending. Waiting ${COOLDOWN_MINUTES}m before restart #${RESTART_COUNT}..."
  sleep $((COOLDOWN_MINUTES * 60))

  # Write sentinel for restart (same mode/merge — skill will see state files and resume)
  write_sentinel
  log "Created restart sentinel."

  log "Restarting Claude Code (restart #${RESTART_COUNT})..."
  run_claude "$PROMPT"
  LAST_EXIT=$?
  log "Restart #${RESTART_COUNT} exited with code $LAST_EXIT"
done

# Clean up
rm -f "$SENTINEL_FILE"

log "============================================"
log "No resumable tasks remain."
log "overnight-runner finished after $((RESTART_COUNT + 1)) total run(s)."
log "============================================"
