#!/bin/bash
#
# dispatch-kimi.sh - Kimi CLI Task Dispatcher
# Zero-polling task scheduling system for OpenClaw
# 
# 对标 (Benchmark): Claude Code Hooks - Full feature parity
#

set -euo pipefail

# =============================================================================
# Auto-load .env file (once)
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
    echo "✅ Loaded environment from $ENV_FILE"
fi

# =============================================================================
# Configuration (Override via environment variables)
# =============================================================================
KIMI_HOOKS_DIR="${KIMI_HOOKS_DIR:-$SCRIPT_DIR}"
OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-http://127.0.0.1:18789}"
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"

# Lock mechanism configuration
LOCK_FILE="${KIMI_HOOKS_DIR}/.hook-lock"
LOCK_TIMEOUT=3  # 3 seconds deduplication window (prevents double-fire but avoids blocking legit retries)

# Pending wake file (fallback channel)
PENDING_WAKE_FILE="${KIMI_HOOKS_DIR}/pending-wake.json"

# =============================================================================
# Usage & Help
# =============================================================================
usage() {
    cat <<EOF
Kimi CLI Task Dispatcher - Zero-polling task scheduling for OpenClaw

Usage: $0 [OPTIONS]

Required:
    -p, --prompt TEXT          Task prompt/description

Optional:
    -n, --name NAME            Task name for tracking
    -g, --group GROUP_ID       Telegram group ID for notifications
    -w, --workdir PATH         Working directory (default: current directory)
    -t, --timeout SECONDS      Timeout in seconds (default: 3600)
    --allowed-tools LIST       Comma-separated list of allowed tools
    -b, --background           Run in background (nohup mode)
    -h, --help                 Show this help message

Examples:
    # Basic task
    $0 -p "Write a Python Hello World program"

    # Named task with notification
    $0 -p "Analyze log files" -n "log-analysis" -g "-1003858994641"

    # Background task with tool restrictions
    $0 -p "Process data" -n "data-job" -w "/data/project" -b --allowed-tools "read,exec"

    # Full-featured task
    $0 -p "Deploy to production" -n "deploy" -g "-1003858994641" -w "/app" -t 7200 -b

EOF
    exit 1
}

# =============================================================================
# Lock Mechanism - Prevent duplicate triggers within 30 seconds
# Uses file modification time (more reliable than reading content)
# =============================================================================
check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_time
        lock_time=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo "0")
        local current_time
        current_time=$(date +%s)
        local time_diff=$((current_time - lock_time))
        
        if [[ $time_diff -lt $LOCK_TIMEOUT ]]; then
            echo "⚠️  Duplicate trigger detected (last trigger: ${time_diff}s ago)" >&2
            echo "    Only processing the first event (deduplication window: ${LOCK_TIMEOUT}s)" >&2
            # Exit with a distinct code so upstream (router/bot) can avoid saying "dispatched"
            exit 2
        fi
    fi
    
    # Create/update lock file (touch updates mtime)
    touch "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# =============================================================================
# Pending Wake File - Fallback notification channel
# =============================================================================
write_pending_wake() {
    local session_id="$1"
    local task_name="$2"
    local status="$3"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%S%z)
    
    local wake_data
    wake_data=$(jq -n \
        --arg type "kimi-task-complete" \
        --arg session_id "$session_id" \
        --arg task_name "$task_name" \
        --arg status "$status" \
        --arg timestamp "$timestamp" \
        --arg workdir "$WORKDIR" \
        '{
            type: $type,
            payload: {
                session_id: $session_id,
                task_name: $task_name,
                status: $status,
                timestamp: $timestamp,
                workdir: $workdir
            },
            created_at: $timestamp
        }')
    
    echo "$wake_data" > "$PENDING_WAKE_FILE"
    echo "📋 Pending wake written: $PENDING_WAKE_FILE"
}

clear_pending_wake() {
    rm -f "$PENDING_WAKE_FILE"
}

# =============================================================================
# Argument Parsing
# =============================================================================
PROMPT=""
TASK_NAME=""
TELEGRAM_GROUP=""
WORKDIR=""
TIMEOUT="3600"
ALLOWED_TOOLS=""
BACKGROUND=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--prompt)
            PROMPT="$2"
            shift 2
            ;;
        -n|--name)
            TASK_NAME="$2"
            shift 2
            ;;
        -g|--group)
            TELEGRAM_GROUP="$2"
            shift 2
            ;;
        -w|--workdir)
            WORKDIR="$2"
            shift 2
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --allowed-tools)
            ALLOWED_TOOLS="$2"
            shift 2
            ;;
        -b|--background)
            BACKGROUND=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown argument $1" >&2
            usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "$PROMPT" ]]; then
    echo "Error: Required parameter -p (prompt)" >&2
    usage
fi

# Set defaults
WORKDIR="${WORKDIR:-$(pwd)}"
TASK_NAME="${TASK_NAME:-kimi-task-$(date +%s)}"
RUN_ID="$(date +%Y%m%d_%H%M%S)_$$"
TASK_DIR="${KIMI_HOOKS_DIR}/runs/${RUN_ID}"

# =============================================================================
# Check for duplicate triggers
# =============================================================================
check_lock

# =============================================================================
# Background Mode - Re-execute with nohup
# [P0 fix] Removed 'local' keyword — not valid outside functions
# =============================================================================
if [[ "$BACKGROUND" == true ]]; then
    echo "🔄 Background mode enabled, detaching process..."
    
    # Build command without --background flag
    cmd_args=()
    cmd_args+=("-p" "$PROMPT")
    cmd_args+=("-n" "$TASK_NAME")
    [[ -n "$TELEGRAM_GROUP" ]] && cmd_args+=("-g" "$TELEGRAM_GROUP")
    [[ -n "$WORKDIR" ]] && cmd_args+=("-w" "$WORKDIR")
    [[ "$TIMEOUT" != "3600" ]] && cmd_args+=("-t" "$TIMEOUT")
    [[ -n "$ALLOWED_TOOLS" ]] && cmd_args+=("--allowed-tools" "$ALLOWED_TOOLS")
    
    # Create log directory
    mkdir -p "${KIMI_HOOKS_DIR}/logs"
    nohup_log="${KIMI_HOOKS_DIR}/logs/${RUN_ID}.log"
    
    # Re-execute with nohup
    nohup "$0" "${cmd_args[@]}" > "$nohup_log" 2>&1 &
    bg_pid=$!
    
    echo "✅ Task running in background (PID: $bg_pid)"
    echo "   Log file: $nohup_log"
    echo "   Task directory: $TASK_DIR"
    
    exit 0
fi

# =============================================================================
# Create Task Directory
# =============================================================================
mkdir -p "$TASK_DIR"

# =============================================================================
# Generate Task Metadata
# =============================================================================
SESSION_ID="kimi-${RUN_ID}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S%z)

cat > "${TASK_DIR}/task-meta.json" <<EOF
{
    "run_id": "${RUN_ID}",
    "session_id": "${SESSION_ID}",
    "timestamp": "${TIMESTAMP}",
    "task_name": "${TASK_NAME}",
    "telegram_group": "${TELEGRAM_GROUP}",
    "cwd": "${WORKDIR}",
    "prompt": $(echo "$PROMPT" | jq -R -s .),
    "timeout": ${TIMEOUT},
    "allowed_tools": "${ALLOWED_TOOLS}",
    "pid": $$,
    "background": ${BACKGROUND},
    "status": "running"
}
EOF

echo "========================================="
echo "🚀 Kimi Task Started"
echo "========================================="
echo "Task ID: ${RUN_ID}"
echo "Session ID: ${SESSION_ID}"
echo "Task Name: ${TASK_NAME}"
echo "Working Directory: ${WORKDIR}"
echo "Timeout: ${TIMEOUT}s"
[[ -n "$ALLOWED_TOOLS" ]] && echo "Allowed Tools: ${ALLOWED_TOOLS}"
echo "Metadata: ${TASK_DIR}/task-meta.json"
echo "========================================="

# =============================================================================
# Cleanup Function
# =============================================================================
cleanup() {
    local exit_code=$?
    local status="done"
    
    if [[ $exit_code -ne 0 ]]; then
        status="failed"
    fi
    
    # Check if interrupted
    if [[ -f "${TASK_DIR}/.signaled" ]]; then
        status="interrupted"
    fi
    
    echo ""
    echo "========================================="
    echo "📝 Task execution ended, status: ${status}"
    echo "========================================="
    
    # [P1 fix] Update task-meta.json with completion status
    if [[ -f "${TASK_DIR}/task-meta.json" ]]; then
        jq --arg code "$exit_code" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S%z)" --arg st "$status" \
            '. + {exit_code: ($code | tonumber), completed_at: $ts, status: $st}' \
            "${TASK_DIR}/task-meta.json" > "${TASK_DIR}/task-meta.json.tmp" \
            && mv "${TASK_DIR}/task-meta.json.tmp" "${TASK_DIR}/task-meta.json"
    fi
    
    # Write to pending wake file (fallback channel)
    write_pending_wake "$SESSION_ID" "$TASK_NAME" "$status"
    
    # Call notification script
    if [[ -f "${KIMI_HOOKS_DIR}/hooks/notify-agi.sh" ]]; then
        bash "${KIMI_HOOKS_DIR}/hooks/notify-agi.sh" "${TASK_DIR}" "$status" "$exit_code" || true
    fi
    
    # Release lock after task completes
    release_lock
    
    exit $exit_code
}

# Set trap for cleanup
trap cleanup EXIT
trap 'echo "Interrupted, exiting gracefully..." >&2; touch "${TASK_DIR}/.signaled"; exit 130' INT TERM

# =============================================================================
# Run Kimi CLI
# =============================================================================
OUTPUT_FILE="${TASK_DIR}/output.log"

# Build kimi-run.py arguments
RUN_ARGS=(
    --prompt "$PROMPT"
    --workdir "$WORKDIR"
    --timeout "$TIMEOUT"
    --meta-file "${TASK_DIR}/task-meta.json"
)

# Add allowed-tools if specified
[[ -n "$ALLOWED_TOOLS" ]] && RUN_ARGS+=(--allowed-tools "$ALLOWED_TOOLS")

echo "🤖 Starting Kimi CLI..."
"${KIMI_HOOKS_DIR}/scripts/kimi-run.py" "${RUN_ARGS[@]}" 2>&1 | tee "$OUTPUT_FILE"

KIMI_EXIT_CODE=${PIPESTATUS[0]}

# Save exit code
echo $KIMI_EXIT_CODE > "${TASK_DIR}/exit-code.txt"

if [[ $KIMI_EXIT_CODE -eq 0 ]]; then
    echo "✅ Kimi task completed successfully"
else
    echo "⚠️  Kimi task exited with code: $KIMI_EXIT_CODE"
fi

exit $KIMI_EXIT_CODE
