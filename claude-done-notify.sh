#!/usr/bin/env bash
# claude-done-notify — Slack notification when Claude Code finishes a turn
# https://github.com/ohade/claude-done-notify
#
# Sends a Slack message when Claude finishes responding and you're not
# looking at the terminal. Supports pane-level focus detection for WezTerm
# on macOS.
#
# Register as a Claude Code hook on UserPromptSubmit and Stop events.
# See README.md for setup instructions.

# ── Configuration ──
# Source user config if present
CONFIG_FILE="${CDN_CONFIG_FILE:-${HOME}/.claude-done-notify.env}"
[[ -f "$CONFIG_FILE" ]] && . "$CONFIG_FILE"

LOG="${CDN_LOG_FILE:-${HOME}/.claude/hooks/debug-claude-done-notify.log}"
exec 2>>"$LOG"

# Required config — exit silently (exit 0) if missing, to never disrupt Claude
if [[ -z "$SLACK_BOT_TOKEN" ]]; then
    echo "$(date '+%H:%M:%S') ERROR: SLACK_BOT_TOKEN not set. See README." >&2
    exit 0
fi
if [[ -z "$SLACK_CHANNEL" ]]; then
    echo "$(date '+%H:%M:%S') ERROR: SLACK_CHANNEL not set. See README." >&2
    exit 0
fi

# Optional config with defaults
SIGNALS_DIR="${CDN_SIGNALS_DIR:-${HOME}/.claude/session-signals}"
MIN_DURATION="${CDN_MIN_DURATION:-10}"
COOLDOWN="${CDN_COOLDOWN:-60}"
FOCUS_DELAY="${CDN_FOCUS_DELAY:-2}"

mkdir -p "$SIGNALS_DIR"

# ── Read hook input from stdin ──
INPUT=$(cat)
echo "$(date '+%H:%M:%S') INPUT=$(echo "$INPUT" | jq -c '.' 2>/dev/null || echo 'parse-error')" >&2

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // empty')

[[ -z "$SESSION_ID" ]] && { echo "$(date '+%H:%M:%S') SKIP: no session_id" >&2; exit 0; }

# ── Handle UserPromptSubmit: save our own start timestamp (no race condition) ──
START_FILE="${SIGNALS_DIR}/${SESSION_ID}.notify-start"
if [[ "$HOOK_EVENT" == "UserPromptSubmit" ]]; then
    date +%s > "$START_FILE"
    exit 0
fi

[[ "$HOOK_EVENT" != "Stop" ]] && exit 0

# ── Duration gate: skip if turn was < MIN_DURATION seconds ──
NOW=$(date +%s)
DURATION=0

if [[ -f "$START_FILE" ]]; then
    WORK_START=$(cat "$START_FILE" 2>/dev/null || echo 0)
    DURATION=$((NOW - WORK_START))
else
    echo "$(date '+%H:%M:%S') SKIP: no start timestamp for $SESSION_ID" >&2
    exit 0
fi

if [[ "$DURATION" -lt "$MIN_DURATION" ]]; then
    echo "$(date '+%H:%M:%S') SKIP: duration ${DURATION}s < ${MIN_DURATION}s" >&2
    exit 0
fi
echo "$(date '+%H:%M:%S') PASS: duration=${DURATION}s" >&2

# ── Rate limit: max 1 notification per COOLDOWN seconds per session ──
LAST_NOTIFIED_FILE="${SIGNALS_DIR}/${SESSION_ID}.last-notified"
if [[ -f "$LAST_NOTIFIED_FILE" ]]; then
    LAST_NOTIFIED=$(cat "$LAST_NOTIFIED_FILE" 2>/dev/null || echo 0)
    ELAPSED=$((NOW - LAST_NOTIFIED))
    if [[ "$ELAPSED" -lt "$COOLDOWN" ]]; then
        echo "$(date '+%H:%M:%S') SKIP: cooldown (${ELAPSED}s < ${COOLDOWN}s)" >&2
        exit 0
    fi
fi

# ── Delay for focus race condition ──
sleep "$FOCUS_DELAY"

# ── Terminal focus detection ──
# Detects whether the user is currently looking at the terminal pane where
# this Claude session is running. If they are, skip the notification.
#
# Supports:
#   - WezTerm (macOS): pane-level detection via wezterm cli + osascript
#   - Generic macOS: app-level detection via osascript (any terminal)
#   - Linux/other: no focus detection (always notifies when filters pass)

PANE_TITLE=""
MY_PANE_ID=""
TAB_NUMBER=""

TERMINAL_MODE="${CDN_TERMINAL:-auto}"
if [[ "$TERMINAL_MODE" == "auto" ]]; then
    command -v wezterm &>/dev/null && TERMINAL_MODE="wezterm" || TERMINAL_MODE="generic"
fi

if [[ "$TERMINAL_MODE" == "wezterm" ]]; then
    MY_TTY=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')
    if [[ -n "$MY_TTY" ]]; then
        PANE_JSON=$(wezterm cli list --format json 2>/dev/null || echo "[]")
        MY_PANE_ID=$(echo "$PANE_JSON" | jq -r --arg tty "/dev/$MY_TTY" \
            '.[] | select(.tty_name == $tty) | .pane_id' 2>/dev/null || echo "")
        PANE_TITLE=$(echo "$PANE_JSON" | jq -r --arg tty "/dev/$MY_TTY" \
            '.[] | select(.tty_name == $tty) | .title' 2>/dev/null || echo "")
        MY_TAB_ID=$(echo "$PANE_JSON" | jq -r --arg tty "/dev/$MY_TTY" \
            '.[] | select(.tty_name == $tty) | .tab_id' 2>/dev/null || echo "")
        if [[ -n "$MY_TAB_ID" ]]; then
            TAB_NUMBER=$(echo "$PANE_JSON" | jq -r '[.[].tab_id] | unique | sort | to_entries[] | select(.value == '"$MY_TAB_ID"') | .key + 1' 2>/dev/null || echo "")
        fi
        echo "$(date '+%H:%M:%S') PANE: tty=$MY_TTY pane=$MY_PANE_ID tab=$TAB_NUMBER title=$PANE_TITLE" >&2
    fi
fi

# Check if user is looking at THIS session's terminal pane (macOS only)
if command -v osascript &>/dev/null; then
    FRONTMOST=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || echo "unknown")

    if [[ "$FRONTMOST" == "wezterm-gui" && "$TERMINAL_MODE" == "wezterm" ]]; then
        if [[ -n "$MY_PANE_ID" ]]; then
            FOCUSED_PANE=$(wezterm cli list-clients --format json 2>/dev/null \
                | jq -r '.[0].focused_pane_id // empty' 2>/dev/null || echo "")
            echo "$(date '+%H:%M:%S') FOCUS: my_pane=$MY_PANE_ID focused=$FOCUSED_PANE" >&2
            if [[ "$MY_PANE_ID" == "$FOCUSED_PANE" ]]; then
                echo "$(date '+%H:%M:%S') SKIP: user is on this exact pane" >&2
                exit 0
            fi
            echo "$(date '+%H:%M:%S') PASS: wezterm focused but different tab" >&2
        else
            echo "$(date '+%H:%M:%S') SKIP: wezterm focused, can't determine pane" >&2
            exit 0
        fi
    elif echo "$FRONTMOST" | grep -qi "terminal\|iterm\|alacritty\|kitty\|wezterm"; then
        # Generic terminal detection — if ANY terminal is focused, skip
        # (can't do pane-level detection for non-WezTerm terminals)
        echo "$(date '+%H:%M:%S') SKIP: terminal app focused ($FRONTMOST)" >&2
        exit 0
    else
        echo "$(date '+%H:%M:%S') PASS: frontmost=$FRONTMOST (not a terminal)" >&2
    fi
else
    echo "$(date '+%H:%M:%S') PASS: no osascript, skipping focus detection" >&2
fi

# ── Build session title ──
SANITIZED_CWD=$(echo "$CWD" | sed 's|/|-|g')
SESSIONS_INDEX="${HOME}/.claude/projects/${SANITIZED_CWD}/sessions-index.json"

SESSION_NAME=""
if [[ -f "$SESSIONS_INDEX" ]]; then
    SESSION_NAME=$(jq -r --arg sid "$SESSION_ID" '
        .entries[] | select(.sessionId == $sid) | .customTitle // empty
    ' "$SESSIONS_INDEX" 2>/dev/null || echo "")

    if [[ -z "$SESSION_NAME" ]]; then
        RAW_PROMPT=$(jq -r --arg sid "$SESSION_ID" '
            .entries[] | select(.sessionId == $sid) | .firstPrompt // empty
        ' "$SESSIONS_INDEX" 2>/dev/null || echo "")
        SESSION_NAME=$(echo "$RAW_PROMPT" \
            | sed 's/<[^>]*>//g' \
            | sed 's/^[[:space:]]*//' \
            | sed '/^$/d' \
            | head -1 \
            | cut -c1-80)
    fi
fi
echo "$(date '+%H:%M:%S') session_name='$SESSION_NAME'" >&2

# Fallback: use WezTerm pane title (often contains /rename'd session name)
if [[ -z "$SESSION_NAME" || "$SESSION_NAME" == "null" ]]; then
    if [[ -n "$PANE_TITLE" ]]; then
        SESSION_NAME=$(echo "$PANE_TITLE" | sed 's/^[^a-zA-Z0-9]*//')
    else
        SESSION_NAME="Claude session"
    fi
fi

# ── Build bottom line from last_assistant_message ──
BOTTOM_LINE=""
RAW_TEXT=""

# Primary: use last_assistant_message from hook stdin
if [[ -n "$LAST_MSG" && "$LAST_MSG" != "null" ]]; then
    RAW_TEXT="$LAST_MSG"
fi

# Fallback: read last assistant text from transcript JSONL
if [[ -z "$RAW_TEXT" && -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    RAW_TEXT=$(tail -100 "$TRANSCRIPT_PATH" 2>/dev/null \
        | jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' 2>/dev/null \
        | tail -1)
fi

if [[ -n "$RAW_TEXT" ]]; then
    BOTTOM_LINE=$(echo "$RAW_TEXT" \
        | sed 's/^#\+[[:space:]]*//' \
        | sed 's/\*\*//g' \
        | sed 's/`//g' \
        | sed 's/<[^>]*>//g' \
        | grep -v '^$' \
        | grep -vi '^\(all done\|here.s the summary\|here.s what\|let me\|i.ll \|done\.\|sure\|okay\|$\)' \
        | head -5 \
        | paste -sd ' ' - \
        | cut -c1-300)
fi

echo "$(date '+%H:%M:%S') bottom_line='$(echo "$BOTTOM_LINE" | cut -c1-50)...'" >&2
[[ -z "$BOTTOM_LINE" ]] && BOTTOM_LINE="Task completed — check terminal for details."

# ── Format the Slack message ──
HEADER="*${SESSION_NAME}*"
if [[ -n "$PANE_TITLE" ]]; then
    CLEAN_PANE=$(echo "$PANE_TITLE" | sed 's/^[^a-zA-Z0-9]*//')
    if [[ -n "$TAB_NUMBER" ]]; then
        HEADER="${HEADER}  ·  _Tab ${TAB_NUMBER}: ${CLEAN_PANE}_"
    else
        HEADER="${HEADER}  ·  _${CLEAN_PANE}_"
    fi
fi

SLACK_TEXT=$(printf '%s\n\n%s' "$HEADER" "$BOTTOM_LINE")

# ── Send Slack message ──
if [[ -n "$SLACK_BOT_TOKEN" && "$SLACK_BOT_TOKEN" != "null" ]]; then
    RESPONSE=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg channel "$SLACK_CHANNEL" \
            --arg text "$SLACK_TEXT" \
            '{channel: $channel, text: $text, unfurl_links: false, unfurl_media: false}')")

    OK=$(echo "$RESPONSE" | jq -r '.ok' 2>/dev/null)
    echo "$(date '+%H:%M:%S') SENT: ok=$OK session=$SESSION_NAME" >&2

    # Record notification timestamp for rate limiting
    echo "$(date +%s)" > "$LAST_NOTIFIED_FILE"
else
    echo "$(date '+%H:%M:%S') ERROR: no slack token" >&2
fi

exit 0
