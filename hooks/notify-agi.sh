#!/bin/bash
#
# notify-agi.sh - Task Completion Notification Script
# Handles result persistence and multi-channel notifications
#
# Notification Channels:
# 1. Wake Event → POST to OpenClaw Gateway (Primary)
# 2. pending-wake.json → AGI heartbeat polling (Fallback)
# 3. Telegram Bot → Push notification (Optional)
#

set -uo pipefail

# =============================================================================
# Configuration (from environment variables)
# =============================================================================
OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-http://127.0.0.1:18789}"
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"

# Output size limits (inspired by Claude Code Hooks)
MAX_OUTPUT_BYTES=4000      # Max bytes to read from output file
MAX_TELEGRAM_BYTES=1000    # Max bytes for Telegram message summary

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
# [P1 fix] Wait for pipe flush before reading output
# Hook may fire before tee finishes writing
# =============================================================================
sleep 1

# =============================================================================
# [P1 fix] Read Task Output — Multi-source fallback (3 levels)
# =============================================================================
OUTPUT=""

# Source 1: task output.log (primary, from dispatch tee)
if [[ -f "$OUTPUT_FILE" ]] && [[ -s "$OUTPUT_FILE" ]]; then
    OUTPUT=$(tail -c $MAX_OUTPUT_BYTES "$OUTPUT_FILE" 2>/dev/null || echo "[Unable to read output file]")
fi

# Source 2: /tmp fallback (if output.log is empty)
TASK_NAME_FROM_META=$(jq -r '.task_name // "unknown"' "$META_FILE" 2>/dev/null || echo "unknown")
TMP_OUTPUT="/tmp/kimi-output-${TASK_NAME_FROM_META}.txt"
if [[ -z "$OUTPUT" ]] && [[ -f "$TMP_OUTPUT" ]] && [[ -s "$TMP_OUTPUT" ]]; then
    OUTPUT=$(tail -c $MAX_OUTPUT_BYTES "$TMP_OUTPUT" 2>/dev/null || echo "")
fi

# Source 3: Working directory listing (last resort)
CWD_FROM_META=$(jq -r '.cwd // "."' "$META_FILE" 2>/dev/null || echo ".")
if [[ -z "$OUTPUT" ]] && [[ -n "$CWD_FROM_META" ]] && [[ -d "$CWD_FROM_META" ]]; then
    FILES=$(ls -1t "$CWD_FROM_META" 2>/dev/null | head -20 | tr '\n' ', ')
    OUTPUT="Working dir: ${CWD_FROM_META}\nRecent files: ${FILES}\n[No task output captured]"
fi

# Final fallback
if [[ -z "$OUTPUT" ]]; then
    OUTPUT="[No output available from any source]"
fi

# =============================================================================
# Extract metadata
# =============================================================================
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
# Strategy: openclaw CLI (primary) → HTTP POST (fallback) → pending-wake.json (always)
# =============================================================================
send_wake_event() {
    # Skip if no gateway token configured
    if [[ -z "$OPENCLAW_GATEWAY_TOKEN" ]]; then
        echo "ℹ️  OPENCLAW_GATEWAY_TOKEN not set, skipping wake event"
        return 0
    fi
    
    local wake_text="[Kimi Task Complete] ${TASK_NAME} — ${STATUS} (exit ${EXIT_CODE})"
    
    # --- Method A: openclaw CLI (primary, uses WebSocket internally) ---
    if command -v openclaw &>/dev/null; then
        local attempt=0
        local max_attempts=2
        while [[ $attempt -lt $max_attempts ]]; do
            if openclaw system event \
                --text "$wake_text" \
                --mode now \
                --token "$OPENCLAW_GATEWAY_TOKEN" \
                --url "ws://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}" \
                --json 2>/dev/null | grep -q '"ok"'; then
                echo "✅ Wake event sent via CLI (attempt $((attempt+1)))"
                return 0
            fi
            attempt=$((attempt + 1))
            if [[ $attempt -lt $max_attempts ]]; then
                echo "⚠️  CLI wake failed, retrying in 2s..."
                sleep 2
            fi
        done
        echo "⚠️  CLI wake failed after ${max_attempts} attempts, trying HTTP fallback..."
    fi
    
    # --- Method B: HTTP POST (fallback, in case future API supports it) ---
    if command -v curl &>/dev/null; then
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
        
        if curl -sf -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${OPENCLAW_GATEWAY_TOKEN}" \
            -d "$event_data" \
            --connect-timeout 5 \
            --max-time 10 \
            "${OPENCLAW_GATEWAY_URL}/api/v1/wake" \
            > /dev/null 2>&1; then
            echo "✅ Wake event sent via HTTP"
            return 0
        fi
        echo "⚠️  HTTP wake also failed (non-critical, pending-wake.json is the safety net)"
    else
        echo "⚠️  Neither openclaw CLI nor curl available for wake event"
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
# [P1 fix] Output truncated to MAX_TELEGRAM_BYTES
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
    
    # [P1 fix] Truncate output for Telegram
    local summary
    summary=$(echo "$OUTPUT" | tail -c $MAX_TELEGRAM_BYTES | tr '\n' ' ')
    
    # Build message
    local message
    message="${status_emoji} <b>Kimi Task Complete</b>

<b>Task:</b> ${TASK_NAME}
<b>Status:</b> ${STATUS}
<b>Exit Code:</b> ${EXIT_CODE}
<b>Working Dir:</b> <code>${CWD}</code>
<b>Time:</b> ${TIMESTAMP}

<pre>${summary:0:800}</pre>"

    # Send message with retry (non-blocking)
    local attempt=0
    local max_attempts=2
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_GROUP}" \
            -d "message_thread_id=14" \
            -d "text=${message}" \
            -d "parse_mode=HTML" \
            --connect-timeout 5 \
            --max-time 10 \
            > /dev/null 2>&1; then
            echo "✅ Telegram notification sent (attempt $((attempt+1)))"
            return 0
        fi
        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_attempts ]]; then
            sleep 2
        fi
    done
    echo "⚠️  Telegram notification failed after ${max_attempts} attempts"
}

# =============================================================================
# Execute Notifications
# =============================================================================
echo ""
echo "========================================="
echo "📬 Sending notifications..."
echo "========================================="

# Update pending wake file (fallback channel — always do this first)
update_pending_wake

# Send wake event (primary channel) - background
send_wake_event &
WAKE_PID=$!

# Send Telegram notification (optional channel) - background
send_telegram_notification &
TG_PID=$!

# Wait for notifications (compatible with bash 4.x+)
wait $WAKE_PID 2>/dev/null || true
wait $TG_PID 2>/dev/null || true

echo "========================================="
echo "✨ Task Complete"
echo "========================================="
echo "Task: $TASK_NAME"
echo "Status: $STATUS"
echo "Session: $SESSION_ID"
echo "Result: $LATEST_FILE"
echo "========================================="

exit 0
