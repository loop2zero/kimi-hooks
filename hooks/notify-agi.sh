#!/bin/bash
#
# notify-agi.sh - Task Completion Notification Script
# Handles result persistence and multi-channel notifications
#
# 通知通道 (Notification Channels):
# 1. Wake Event → POST to OpenClaw Gateway (Primary)
# 2. pending-wake.json → AGI heartbeat polling (Fallback)
# 3. Telegram Bot → Push notification (Optional)
#

set -euo pipefail

# =============================================================================
# Configuration (from environment variables)
# =============================================================================
OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-http://127.0.0.1:18789}"
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"

# =============================================================================
# Argument Validation
# =============================================================================
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <task-dir> <status> [exit-code]" >&2
    exit 1
fi

TASK_DIR="$1"
STATUS="$2"
EXIT_CODE="${3:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META_FILE="${TASK_DIR}/task-meta.json"
OUTPUT_FILE="${TASK_DIR}/output.log"
LATEST_FILE="${SCRIPT_DIR}/latest.json"
PENDING_WAKE_FILE="${SCRIPT_DIR}/pending-wake.json"

# Validate metadata file
if [[ ! -f "$META_FILE" ]]; then
    echo "Error: Metadata file not found: $META_FILE" >&2
    exit 1
fi

# =============================================================================
# Read Task Data
# =============================================================================
OUTPUT=""
if [[ -f "$OUTPUT_FILE" ]]; then
    OUTPUT=$(cat "$OUTPUT_FILE" 2>/dev/null || echo "[Unable to read output file]")
else
    OUTPUT="[No output file]"
fi

# Extract metadata
SESSION_ID=$(jq -r '.session_id // "unknown"' "$META_FILE")
TASK_NAME=$(jq -r '.task_name // "unknown"' "$META_FILE")
TELEGRAM_GROUP=$(jq -r '.telegram_group // ""' "$META_FILE")
CWD=$(jq -r '.cwd // "."' "$META_FILE")
ALLOWED_TOOLS=$(jq -r '.allowed_tools // ""' "$META_FILE")
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S%z)

# =============================================================================
# Build Result JSON
# =============================================================================
RESULT_JSON=$(jq -n \
    --arg session_id "$SESSION_ID" \
    --arg timestamp "$TIMESTAMP" \
    --arg task_name "$TASK_NAME" \
    --arg telegram_group "$TELEGRAM_GROUP" \
    --arg cwd "$CWD" \
    --arg allowed_tools "$ALLOWED_TOOLS" \
    --arg output "$OUTPUT" \
    --arg status "$STATUS" \
    --argjson exit_code "$EXIT_CODE" \
    '{
        session_id: $session_id,
        timestamp: $timestamp,
        task_name: $task_name,
        telegram_group: $telegram_group,
        cwd: $cwd,
        allowed_tools: $allowed_tools,
        output: $output,
        status: $status,
        exit_code: $exit_code
    }')

# Write to latest.json
echo "$RESULT_JSON" > "$LATEST_FILE"
echo "✅ Result written: $LATEST_FILE"

# Also save to task directory
echo "$RESULT_JSON" > "${TASK_DIR}/result.json"
echo "✅ Result written: ${TASK_DIR}/result.json"

# =============================================================================
# Channel 1: Send Wake Event to OpenClaw Gateway
# =============================================================================
send_wake_event() {
    # Skip if no gateway token configured
    if [[ -z "$OPENCLAW_GATEWAY_TOKEN" ]]; then
        echo "ℹ️  OPENCLAW_GATEWAY_TOKEN not set, skipping wake event"
        return 0
    fi
    
    local event_data
    event_data=$(jq -n \
        --arg type "kimi-task-complete" \
        --arg session_id "$SESSION_ID" \
        --arg task_name "$TASK_NAME" \
        --arg status "$STATUS" \
        --arg timestamp "$TIMESTAMP" \
        '{
            type: $type,
            payload: {
                session_id: $session_id,
                task_name: $task_name,
                status: $status,
                timestamp: $timestamp
            }
        }')
    
    # Attempt to send wake event (non-blocking, failures ignored)
    if command -v curl &>/dev/null; then
        curl -s -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${OPENCLAW_GATEWAY_TOKEN}" \
            -d "$event_data" \
            "${OPENCLAW_GATEWAY_URL}/api/v1/wake" \
            > /dev/null 2>&1 && echo "✅ Wake event sent" || echo "⚠️  Wake event failed (non-critical)"
    else
        echo "⚠️  curl not installed, skipping wake event"
    fi
}

# =============================================================================
# Channel 2: Update Pending Wake File (Fallback for AGI heartbeat)
# =============================================================================
update_pending_wake() {
    local wake_data
    wake_data=$(jq -n \
        --arg type "kimi-task-complete" \
        --arg session_id "$SESSION_ID" \
        --arg task_name "$TASK_NAME" \
        --arg status "$STATUS" \
        --arg timestamp "$TIMESTAMP" \
        --arg cwd "$CWD" \
        --arg result_file "$LATEST_FILE" \
        '{
            type: $type,
            payload: {
                session_id: $session_id,
                task_name: $task_name,
                status: $status,
                timestamp: $timestamp,
                workdir: $cwd,
                result_file: $result_file
            },
            notified: false,
            created_at: $timestamp
        }')
    
    echo "$wake_data" > "$PENDING_WAKE_FILE"
    echo "✅ Pending wake updated: $PENDING_WAKE_FILE"
}

# =============================================================================
# Channel 3: Send Telegram Notification (Optional)
# =============================================================================
send_telegram_notification() {
    # Skip if not configured
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_GROUP" ]]; then
        echo "ℹ️  Telegram not configured, skipping notification"
        return 0
    fi
    
    # Status emoji
    local status_emoji
    case "$STATUS" in
        done) status_emoji="✅" ;;
        failed) status_emoji="❌" ;;
        interrupted) status_emoji="⚠️" ;;
        *) status_emoji="ℹ️" ;;
    esac
    
    # Build message
    local message
    message="${status_emoji} <b>Kimi Task Complete</b>

<b>Task:</b> ${TASK_NAME}
<b>Status:</b> ${STATUS}
<b>Exit Code:</b> ${EXIT_CODE}
<b>Working Dir:</b> <code>${CWD}</code>
<b>Time:</b> ${TIMESTAMP}

<pre>$(echo "$OUTPUT" | tail -30)</pre>"

    # Send message (non-blocking, failures ignored)
    curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_GROUP}" \
        -d "text=${message}" \
        -d "parse_mode=HTML" \
        > /dev/null 2>&1 && echo "✅ Telegram notification sent" || echo "⚠️  Telegram notification failed"
}

# =============================================================================
# Execute Notifications
# =============================================================================
echo ""
echo "========================================="
echo "📬 Sending notifications..."
echo "========================================="

# Update pending wake file (fallback channel)
update_pending_wake

# Send wake event (primary channel) - background
send_wake_event &
WAKE_PID=$!

# Send Telegram notification (optional channel) - background
send_telegram_notification &
TG_PID=$!

# Wait for notifications (max 5 seconds)
wait -f $WAKE_PID $TG_PID 2>/dev/null || true
sleep 1

echo "========================================="
echo "✨ Task Complete"
echo "========================================="
echo "Task: $TASK_NAME"
echo "Status: $STATUS"
echo "Session: $SESSION_ID"
echo "Result: $LATEST_FILE"
echo "========================================="

exit 0
