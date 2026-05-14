#!/usr/bin/env bash
# claude-done-notify — Slack notification when an agent finishes a turn
# https://github.com/ohade/claude-done-notify
#
# Sends a Slack message when Claude/Codex finishes responding and you're not
# looking at the terminal. Supports pane-level focus detection for WezTerm
# on macOS.
#
# Register as a Claude Code or Codex hook on UserPromptSubmit and Stop events.
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
AGENT_NAME="${CDN_AGENT_NAME:-Claude}"

mkdir -p "$SIGNALS_DIR"

# ── Terminal helpers (CC-97) ──
# Pure functions — no I/O beyond reading env + token file. Single source of truth
# for the cmux > ghostty > wezterm > generic precedence (mirrors
# ~/.claude/hooks/lib/terminal_identity.sh). The cmux dispatch row is inert
# until CC-64D adds the runtime detection block.

# detect_terminal_mode: echoes one of cmux | ghostty | wezterm | generic.
# Honors $CDN_TERMINAL override (any value other than "auto" is returned verbatim).
# Reads: CDN_TERMINAL, CMUX_SURFACE_ID, CMUX_PANEL_ID, GHOSTTY_TERMINAL_ID, PATH (for wezterm).
detect_terminal_mode() {
    if [[ -n "${CDN_TERMINAL:-}" && "${CDN_TERMINAL}" != "auto" ]]; then
        echo "$CDN_TERMINAL"
        return 0
    fi
    if [[ -n "${CMUX_SURFACE_ID:-}" || -n "${CMUX_PANEL_ID:-}" ]]; then
        echo "cmux"
    elif [[ -n "${GHOSTTY_TERMINAL_ID:-}" ]]; then
        echo "ghostty"
    elif command -v wezterm &>/dev/null; then
        echo "wezterm"
    else
        echo "generic"
    fi
}

# build_focus_link: echoes a focus URL or empty string. Empty if id is missing,
# terminal type is unknown/generic, or required cmux preconditions are unmet.
# Args:
#   $1 terminal_type — cmux | ghostty | wezterm | generic | <other>
#   $2 id            — pane id (wezterm), terminal id (ghostty), surface id (cmux)
#   $3 extra         — workspace id (cmux only); ignored for other types
# Reads: CDN_FOCUS_PORT (wezterm, default 17380), CDN_GHOSTTY_FOCUS_PORT (default 17381),
#        CDN_CMUX_FOCUS_PORT (default 17382), CDN_CMUX_FOCUS_TOKEN_FILE (default ~/.cmux-focus-token).
build_focus_link() {
    local terminal_type="$1"
    local id="$2"
    local extra="${3:-}"
    [[ -z "$id" ]] && { echo ""; return 0; }

    case "$terminal_type" in
        cmux)
            # CMUX_FOCUS_DISABLE=1 kill switch (CC-95 audit fix).
            # Per-invocation opt-out without unloading the LaunchAgent or
            # removing the token file. Slack message is still sent, just
            # without the focus URL — same behavior as missing token.
            if [[ "${CMUX_FOCUS_DISABLE:-0}" == "1" ]]; then
                echo ""
                return 0
            fi
            local port="${CDN_CMUX_FOCUS_PORT:-17382}"
            local token_file="${CDN_CMUX_FOCUS_TOKEN_FILE:-${HOME}/.cmux-focus-token}"
            local token=""
            [[ -f "$token_file" ]] && token=$(cat "$token_file" 2>/dev/null)
            # Missing token or workspace → empty link (no focus, but Slack
            # message still sent).
            if [[ -n "$token" && -n "$extra" ]]; then
                echo "http://127.0.0.1:${port}/focus?token=${token}&workspace=${extra}&surface=${id}"
            else
                echo ""
            fi
            ;;
        ghostty)
            local port="${CDN_GHOSTTY_FOCUS_PORT:-17381}"
            echo "http://127.0.0.1:${port}/focus?pane=${id}"
            ;;
        wezterm)
            local port="${CDN_FOCUS_PORT:-17380}"
            echo "http://127.0.0.1:${port}/focus?pane=${id}"
            ;;
        *)
            echo ""
            ;;
    esac
}

normalize_hook_event() {
    local raw lowered compact
    raw="${1:-}"
    lowered=$(echo "$raw" | tr '[:upper:]' '[:lower:]')
    compact=$(echo "$lowered" | tr -d '_- ')
    case "$compact" in
        userpromptsubmit|promptsubmit)
            echo "UserPromptSubmit"
            ;;
        stop)
            echo "Stop"
            ;;
        *)
            echo "$raw"
            ;;
    esac
}

cmux_agent_key() {
    local lowered
    lowered=$(echo "${AGENT_NAME:-Claude}" | tr '[:upper:]' '[:lower:]')
    case "$lowered" in
        codex*) echo "codex" ;;
        *) echo "claude" ;;
    esac
}

read_cmux_session_identity() {
    local agent_key state_file
    agent_key=$(cmux_agent_key)
    state_file="${HOME}/.cmuxterm/${agent_key}-hook-sessions.json"
    [[ -n "${SESSION_ID:-}" && -f "$state_file" ]] || return 0
    jq -r --arg sid "$SESSION_ID" '
        .sessions[$sid]?
        | select(.workspaceId and .surfaceId)
        | "\(.workspaceId)|\(.surfaceId)"
    ' "$state_file" 2>/dev/null | head -1
}

cmux_workspace_from_identify() {
    jq -r '
        .caller.workspace_id // .caller.workspaceId //
        .caller.workspace_ref // .caller.workspaceRef //
        .focused.workspace_id // .focused.workspaceId //
        .focused.workspace_ref // .focused.workspaceRef // empty
    ' 2>/dev/null
}

cmux_surface_from_identify() {
    jq -r '
        .caller.surface_id // .caller.surfaceId //
        .caller.panel_id // .caller.panelId //
        .caller.surface_ref // .caller.surfaceRef //
        .caller.panel_ref // .caller.panelRef //
        .focused.surface_id // .focused.surfaceId //
        .focused.panel_id // .focused.panelId //
        .focused.surface_ref // .focused.surfaceRef //
        .focused.panel_ref // .focused.panelRef // empty
    ' 2>/dev/null
}

capture_cmux_identity() {
    local ws sf state_line identify_json
    ws="${CMUX_WORKSPACE_ID:-}"
    sf="${CMUX_SURFACE_ID:-${CMUX_PANEL_ID:-}}"

    if [[ -z "$ws" || -z "$sf" ]]; then
        state_line=$(read_cmux_session_identity)
        if [[ -n "$state_line" ]]; then
            [[ -z "$ws" ]] && ws=$(echo "$state_line" | cut -d'|' -f1)
            [[ -z "$sf" ]] && sf=$(echo "$state_line" | cut -d'|' -f2)
        fi
    fi

    if command -v cmux &>/dev/null &&
       [[ -z "$ws" || -z "$sf" ]] &&
       [[ "${CDN_TERMINAL:-auto}" == "cmux" || -n "${CMUX_WORKSPACE_ID:-}${CMUX_SURFACE_ID:-}${CMUX_PANEL_ID:-}" ]]; then
        identify_json=$(cmux identify 2>/dev/null || echo "{}")
        [[ -z "$ws" ]] && ws=$(echo "$identify_json" | cmux_workspace_from_identify)
        [[ -z "$sf" ]] && sf=$(echo "$identify_json" | cmux_surface_from_identify)
    fi

    [[ -n "$ws" && -n "$sf" ]] && printf '%s|%s\n' "$ws" "$sf"
}

# ── Read hook input from stdin ──
INPUT=$(cat)
echo "$(date '+%H:%M:%S') INPUT=$(echo "$INPUT" | jq -c '.' 2>/dev/null || echo 'parse-error')" >&2

HOOK_EVENT_ARG="${1:-}"
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // .sessionId // empty')
if [[ -z "$SESSION_ID" && -n "${CODEX_THREAD_ID:-}" ]]; then
    SESSION_ID="$CODEX_THREAD_ID"
fi
HOOK_EVENT_RAW="${HOOK_EVENT_ARG:-$(echo "$INPUT" | jq -r '.hook_event_name // .hookEventName // .event_name // .eventName // .event // empty')}"
HOOK_EVENT=$(normalize_hook_event "$HOOK_EVENT_RAW")
CWD=$(echo "$INPUT" | jq -r '.cwd // .working_directory // .workingDirectory // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // .transcriptPath // empty')
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // .lastAssistantMessage // .last_agent_message // .lastAgentMessage // empty')

[[ -z "$SESSION_ID" ]] && { echo "$(date '+%H:%M:%S') SKIP: no session_id" >&2; exit 0; }

# ── Suppression: skip when called from automated claude -p subprocesses ──
if [[ "${CDN_SUPPRESS:-0}" == "1" ]]; then
    echo "$(date '+%H:%M:%S') SKIP: CDN_SUPPRESS=1 (automated subprocess)" >&2
    exit 0
fi

# ── Handle UserPromptSubmit: save start timestamp + Ghostty tab info ──
START_FILE="${SIGNALS_DIR}/${SESSION_ID}.notify-start"
TAB_INFO_FILE="${SIGNALS_DIR}/${SESSION_ID}.tab-info"
CMUX_INFO_FILE="${SIGNALS_DIR}/${SESSION_ID}.cmux-info"
if [[ "$HOOK_EVENT" == "UserPromptSubmit" ]]; then
    date +%s > "$START_FILE"
    _CMUX_LINE=$(capture_cmux_identity)
    if [[ -n "$_CMUX_LINE" ]]; then
        echo "$_CMUX_LINE" > "$CMUX_INFO_FILE"
    fi
    # For Ghostty: save the real tab info NOW (before Stop hooks overwrite the title).
    # Uses TTY probe to find the correct terminal even if GHOSTTY_TERMINAL_ID is stale.
    if [[ -n "$GHOSTTY_TERMINAL_ID" ]]; then
        _WALK_PID=$PPID; _REAL_TTY=""
        for _i in 1 2 3 4 5 6; do
            _INFO=$(ps -o pid=,ppid=,tty= -p $_WALK_PID 2>/dev/null | head -1)
            _TTY=$(echo "$_INFO" | awk '{print $3}')
            if [[ "$_TTY" != "??" && -n "$_TTY" ]]; then _REAL_TTY="$_TTY"; break; fi
            _WALK_PID=$(echo "$_INFO" | awk '{print $2}')
            [[ -z "$_WALK_PID" || "$_WALK_PID" == "0" ]] && break
        done
        if [[ -n "$_REAL_TTY" && -w "/dev/$_REAL_TTY" ]]; then
            _ALL=$(osascript -e '
                tell application "Ghostty"
                    set output to ""
                    repeat with w in every window
                        repeat with t in every tab of w
                            repeat with trm in every terminal of t
                                set output to output & id of trm & "|" & index of t & "|" & name of t & linefeed
                            end repeat
                        end repeat
                    end repeat
                    return output
                end tell
            ' 2>/dev/null || echo "")
            _PROBE="__CDN_${RANDOM}_$$__"
            echo -ne "\033]2;${_PROBE}\007" > "/dev/$_REAL_TTY" 2>/dev/null
            sleep 0.15
            _FOUND_ID=$(osascript -e '
                tell application "Ghostty"
                    repeat with w in every window
                        repeat with t in every tab of w
                            repeat with trm in every terminal of t
                                if name of trm contains "'"$_PROBE"'" then return id of trm as text
                            end repeat
                        end repeat
                    end repeat
                    return ""
                end tell
            ' 2>/dev/null || echo "")
            if [[ -n "$_FOUND_ID" ]]; then
                _LINE=$(echo "$_ALL" | grep "^${_FOUND_ID}|" | head -1)
                echo "${_FOUND_ID}|$(echo "$_LINE" | cut -d'|' -f2)|$(echo "$_LINE" | cut -d'|' -f3-)" > "$TAB_INFO_FILE"
                # Restore original title
                _ORIG_TITLE=$(echo "$_LINE" | cut -d'|' -f3-)
                echo -ne "\033]2;${_ORIG_TITLE}\007" > "/dev/$_REAL_TTY" 2>/dev/null
            else
                echo -ne "\033]2;\007" > "/dev/$_REAL_TTY" 2>/dev/null
            fi
        fi
    fi
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
MY_WORKSPACE_ID=""
MY_PANE_REF=""
MY_WORKSPACE_REF=""
TAB_NUMBER=""

# CC-97: terminal-mode detection lives in detect_terminal_mode() (top of file).
TERMINAL_MODE=$(detect_terminal_mode)
if [[ "$TERMINAL_MODE" == "generic" && -f "$CMUX_INFO_FILE" ]]; then
    TERMINAL_MODE="cmux"
fi

# ── cmux runtime identity (CC-64D) ──
if [[ "$TERMINAL_MODE" == "cmux" ]]; then
    MY_WORKSPACE_ID="${CMUX_WORKSPACE_ID:-}"
    MY_PANE_ID="${CMUX_SURFACE_ID:-${CMUX_PANEL_ID:-}}"
    if [[ -z "$MY_WORKSPACE_ID" || -z "$MY_PANE_ID" ]]; then
        _CMUX_LINE=$(capture_cmux_identity)
        if [[ -n "$_CMUX_LINE" ]]; then
            [[ -z "$MY_WORKSPACE_ID" ]] && MY_WORKSPACE_ID=$(echo "$_CMUX_LINE" | cut -d'|' -f1)
            [[ -z "$MY_PANE_ID" ]] && MY_PANE_ID=$(echo "$_CMUX_LINE" | cut -d'|' -f2)
        fi
    fi
    PANE_TITLE=""
    TAB_NUMBER=""
    # Optional cmux identify enrichment. Newer cmux returns refs
    # (workspace:10/surface:34) instead of UUID fields, so keep both forms.
    if command -v cmux &>/dev/null; then
        _ID_ARGS=()
        [[ -n "$MY_WORKSPACE_ID" ]] && _ID_ARGS+=(--workspace "$MY_WORKSPACE_ID")
        [[ -n "$MY_PANE_ID" ]] && _ID_ARGS+=(--surface "$MY_PANE_ID")
        _ID_JSON=$(cmux identify "${_ID_ARGS[@]}" 2>/dev/null || echo "{}")
        [[ -z "$MY_WORKSPACE_ID" ]] && MY_WORKSPACE_ID=$(echo "$_ID_JSON" | cmux_workspace_from_identify)
        [[ -z "$MY_PANE_ID" ]] && MY_PANE_ID=$(echo "$_ID_JSON" | cmux_surface_from_identify)
        MY_WORKSPACE_REF=$(echo "$_ID_JSON" | jq -r '.caller.workspace_ref // .caller.workspaceRef // empty' 2>/dev/null || echo "")
        MY_PANE_REF=$(echo "$_ID_JSON" | jq -r '.caller.surface_ref // .caller.surfaceRef // .caller.panel_ref // .caller.panelRef // empty' 2>/dev/null || echo "")
    fi
    echo "$(date '+%H:%M:%S') PANE: cmux ws=$MY_WORKSPACE_ID surface=$MY_PANE_ID ws_ref=$MY_WORKSPACE_REF surface_ref=$MY_PANE_REF" >&2
fi

# ── WezTerm runtime identity ──
if [[ "$TERMINAL_MODE" == "wezterm" ]]; then
    PANE_JSON=$(wezterm cli list --format json 2>/dev/null || echo "[]")
    # Prefer WEZTERM_PANE env var (works through PTY proxies like claude-chill)
    # Fall back to PPID→TTY matching for non-proxy setups
    if [[ -n "$WEZTERM_PANE" ]]; then
        MY_PANE_ID="$WEZTERM_PANE"
        PANE_TITLE=$(echo "$PANE_JSON" | jq -r --argjson pid "$MY_PANE_ID" \
            '.[] | select(.pane_id == $pid) | .title' 2>/dev/null || echo "")
        MY_TAB_ID=$(echo "$PANE_JSON" | jq -r --argjson pid "$MY_PANE_ID" \
            '.[] | select(.pane_id == $pid) | .tab_id' 2>/dev/null || echo "")
    else
        MY_TTY=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')
        if [[ -n "$MY_TTY" ]]; then
            MY_PANE_ID=$(echo "$PANE_JSON" | jq -r --arg tty "/dev/$MY_TTY" \
                '.[] | select(.tty_name == $tty) | .pane_id' 2>/dev/null || echo "")
            PANE_TITLE=$(echo "$PANE_JSON" | jq -r --arg tty "/dev/$MY_TTY" \
                '.[] | select(.tty_name == $tty) | .title' 2>/dev/null || echo "")
            MY_TAB_ID=$(echo "$PANE_JSON" | jq -r --arg tty "/dev/$MY_TTY" \
                '.[] | select(.tty_name == $tty) | .tab_id' 2>/dev/null || echo "")
        fi
    fi
    if [[ -n "$MY_TAB_ID" ]]; then
        TAB_NUMBER=$(echo "$PANE_JSON" | jq -r '[.[].tab_id] | unique | sort | to_entries[] | select(.value == '"$MY_TAB_ID"') | .key + 1' 2>/dev/null || echo "")
    fi
    echo "$(date '+%H:%M:%S') PANE: pane=$MY_PANE_ID tab=$TAB_NUMBER title=$PANE_TITLE (src=${WEZTERM_PANE:+env}${WEZTERM_PANE:-tty})" >&2
fi

if [[ "$TERMINAL_MODE" == "ghostty" ]]; then
    # Read tab info cached during UserPromptSubmit (before Stop hooks overwrite the title).
    # Format: terminal_id|tab_index|tab_title
    TAB_INFO_FILE="${SIGNALS_DIR}/${SESSION_ID}.tab-info"
    MY_PANE_ID="$GHOSTTY_TERMINAL_ID"
    if [[ -f "$TAB_INFO_FILE" ]]; then
        _CACHED=$(cat "$TAB_INFO_FILE")
        MY_PANE_ID=$(echo "$_CACHED" | cut -d'|' -f1)
        TAB_NUMBER=$(echo "$_CACHED" | cut -d'|' -f2)
        PANE_TITLE=$(echo "$_CACHED" | cut -d'|' -f3-)
    fi
    # Refresh tab index at Stop time (may have shifted since UserPromptSubmit)
    _FRESH_IDX=$(osascript -e '
        tell application "Ghostty"
            repeat with w in every window
                repeat with t in every tab of w
                    repeat with trm in every terminal of t
                        if id of trm is "'"$MY_PANE_ID"'" then return index of t as text
                    end repeat
                end repeat
            end repeat
            return ""
        end tell
    ' 2>/dev/null || echo "")
    if [[ -n "$_FRESH_IDX" ]]; then
        TAB_NUMBER="$_FRESH_IDX"
    fi
    echo "$(date '+%H:%M:%S') PANE: terminal_id=$MY_PANE_ID tab=$TAB_NUMBER title=$PANE_TITLE (ghostty, fresh idx)" >&2
fi

# Check if user is looking at THIS session's terminal pane (macOS only)
if command -v osascript &>/dev/null; then
    FRONTMOST=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || echo "unknown")

    if [[ "$FRONTMOST" == "ghostty" && "$TERMINAL_MODE" == "ghostty" ]]; then
        if [[ -n "$MY_PANE_ID" ]]; then
            # Check if the tab containing our terminal is the selected tab.
            # We check tab-level (not terminal-level) because GHOSTTY_TERMINAL_ID
            # can be stale if a session was resumed in a different tab.
            MY_TAB_SELECTED=$(osascript -e '
                tell application "Ghostty"
                    set targetID to "'"$MY_PANE_ID"'"
                    set fw to front window
                    repeat with t in every tab of fw
                        repeat with trm in every terminal of t
                            if id of trm is targetID then
                                return selected of t as text
                            end if
                        end repeat
                    end repeat
                    return "not_found"
                end tell
            ' 2>/dev/null || echo "error")
            echo "$(date '+%H:%M:%S') FOCUS: my_terminal=$MY_PANE_ID tab_selected=$MY_TAB_SELECTED" >&2
            if [[ "$MY_TAB_SELECTED" == "true" ]]; then
                echo "$(date '+%H:%M:%S') SKIP: user is on the tab containing this session" >&2
                exit 0
            fi
            if [[ "$MY_TAB_SELECTED" == "not_found" ]]; then
                # Terminal ID not found in any tab — likely stale env var.
                # Fall back: check if ANY Claude tab is selected (conservative skip)
                echo "$(date '+%H:%M:%S') WARN: terminal $MY_PANE_ID not found in any tab (stale env?)" >&2
            fi
            echo "$(date '+%H:%M:%S') PASS: ghostty focused but different tab" >&2
        else
            echo "$(date '+%H:%M:%S') SKIP: ghostty focused, can't determine terminal" >&2
            exit 0
        fi
    elif [[ "$FRONTMOST" == "wezterm-gui" && "$TERMINAL_MODE" == "wezterm" ]]; then
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
    elif echo "$FRONTMOST" | grep -qi "^cmux$" && [[ "$TERMINAL_MODE" == "cmux" ]]; then
        # System Events may report either "cmux" or "Cmux"; use an exact,
        # case-insensitive match so unrelated app names do not fall through here.
        if [[ -n "$MY_PANE_ID" && -n "$MY_WORKSPACE_ID" ]]; then
            # focused.surface_id reflects what the user is looking at now, not
            # what the env var said at session start. If identify is unavailable,
            # conservatively skip because cmux itself is frontmost.
            if ! command -v cmux &>/dev/null; then
                echo "$(date '+%H:%M:%S') SKIP: cmux focused, identify unavailable" >&2
                exit 0
            fi
            FOCUSED_JSON=$(cmux identify 2>/dev/null || echo "{}")
            FOCUSED_WS=$(echo "$FOCUSED_JSON" | jq -r '.focused.workspace_id // .focused.workspaceId // empty' 2>/dev/null || echo "")
            FOCUSED_SF=$(echo "$FOCUSED_JSON" | jq -r '.focused.surface_id // .focused.surfaceId // .focused.panel_id // .focused.panelId // empty' 2>/dev/null || echo "")
            FOCUSED_WS_REF=$(echo "$FOCUSED_JSON" | jq -r '.focused.workspace_ref // .focused.workspaceRef // empty' 2>/dev/null || echo "")
            FOCUSED_SF_REF=$(echo "$FOCUSED_JSON" | jq -r '.focused.surface_ref // .focused.surfaceRef // .focused.panel_ref // .focused.panelRef // empty' 2>/dev/null || echo "")
            echo "$(date '+%H:%M:%S') FOCUS: my=$MY_WORKSPACE_ID/$MY_PANE_ID refs=$MY_WORKSPACE_REF/$MY_PANE_REF focused=$FOCUSED_WS/$FOCUSED_SF refs=$FOCUSED_WS_REF/$FOCUSED_SF_REF" >&2
            if [[ -z "$FOCUSED_WS$FOCUSED_WS_REF" || -z "$FOCUSED_SF$FOCUSED_SF_REF" ]]; then
                echo "$(date '+%H:%M:%S') SKIP: cmux focused, identify returned no focused surface" >&2
                exit 0
            fi
            if { [[ -n "$FOCUSED_WS" && "$MY_WORKSPACE_ID" == "$FOCUSED_WS" ]] || [[ -n "$FOCUSED_WS_REF" && "$MY_WORKSPACE_REF" == "$FOCUSED_WS_REF" ]]; } &&
               { [[ -n "$FOCUSED_SF" && "$MY_PANE_ID" == "$FOCUSED_SF" ]] || [[ -n "$FOCUSED_SF_REF" && "$MY_PANE_REF" == "$FOCUSED_SF_REF" ]]; }; then
                echo "$(date '+%H:%M:%S') SKIP: user is on this exact cmux surface" >&2
                exit 0
            fi
            echo "$(date '+%H:%M:%S') PASS: cmux focused but different surface" >&2
        else
            echo "$(date '+%H:%M:%S') SKIP: cmux focused, missing ws/surface env" >&2
            exit 0
        fi
    elif echo "$FRONTMOST" | grep -qi "terminal\|iterm\|alacritty\|kitty\|wezterm\|ghostty"; then
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
        SESSION_NAME="${AGENT_NAME} session"
    fi
fi

# ── Build message body from last_assistant_message ──
# Two versions: TLDR (push notification) and FULL_BODY (in-app blocks)
TLDR=""
FULL_BODY=""
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

# Codex transcript fallback: final-answer agent_message or task_complete payload.
if [[ -z "$RAW_TEXT" && -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    RAW_TEXT=$(tail -200 "$TRANSCRIPT_PATH" 2>/dev/null \
        | jq -r '
            select(.type == "event_msg")
            | select(.payload.type == "agent_message" or .payload.type == "task_complete")
            | (.payload.message // .payload.last_agent_message // empty)
        ' 2>/dev/null \
        | tail -1)
fi

FORMATTER="$(dirname "$0")/format-slack.py"
if [[ -n "$RAW_TEXT" && -f "$FORMATTER" ]]; then
    TLDR=$(echo "$RAW_TEXT" | python3 "$FORMATTER" --tldr)
    FULL_BODY=$(echo "$RAW_TEXT" | python3 "$FORMATTER" --max-lines 8 --max-chars 800)
elif [[ -n "$RAW_TEXT" ]]; then
    # Fallback if formatter missing: basic cleanup
    CLEANED=$(echo "$RAW_TEXT" \
        | sed 's/^#\+[[:space:]]*//' \
        | sed 's/\*\*//g' \
        | sed 's/<[^>]*>//g' \
        | grep -v '^$')
    TLDR=$(echo "$CLEANED" | sed 's/`//g' | head -2 | paste -sd ' ' - | cut -c1-150)
    FULL_BODY=$(echo "$CLEANED" | head -40 | cut -c1-200)
    FULL_BODY="${FULL_BODY:0:2900}"
fi

echo "$(date '+%H:%M:%S') tldr='$(echo "$TLDR" | cut -c1-50)...' full_len=${#FULL_BODY}" >&2
[[ -z "$TLDR" ]] && TLDR="Task completed — check terminal for details."
[[ -z "$FULL_BODY" ]] && FULL_BODY="$TLDR"

# ── Format duration for display ──
if [[ "$DURATION" -ge 60 ]]; then
    DURATION_DISPLAY="$((DURATION / 60))m $((DURATION % 60))s"
else
    DURATION_DISPLAY="${DURATION}s"
fi

# ── Build focus link (CC-97: dispatched via build_focus_link helper) ──
# cmux dispatch row is inert until CC-64D adds the runtime detection block
# (which will populate $MY_WORKSPACE_ID alongside $MY_PANE_ID = surface_id).
FOCUS_LINK=$(build_focus_link "$TERMINAL_MODE" "$MY_PANE_ID" "${MY_WORKSPACE_ID:-}")

# ── Build location line ──
LOCATION=""
if [[ -n "$PANE_TITLE" ]]; then
    CLEAN_PANE=$(echo "$PANE_TITLE" | sed 's/^[^a-zA-Z0-9]*//')
    if [[ -n "$TAB_NUMBER" ]]; then
        LOCATION="Tab ${TAB_NUMBER}"
    fi
fi

# ── Short CWD (last 2 path components) ──
SHORT_CWD=""
if [[ -n "$CWD" ]]; then
    SHORT_CWD=$(echo "$CWD" | awk -F/ '{if(NF>=2) print $(NF-1)"/"$NF; else print $NF}')
fi

# ── Build Slack Block Kit message ──
# Context-aware emoji based on session name, TLDR, and working directory
_SN_LOWER=$(echo "$SESSION_NAME" | tr '[:upper:]' '[:lower:]')
_TLDR_LOWER=$(echo "$TLDR" | tr '[:upper:]' '[:lower:]')
_CWD_LOWER=$(echo "$SHORT_CWD" | tr '[:upper:]' '[:lower:]')
STATUS_EMOJI=":white_check_mark:"
if echo "$_SN_LOWER $_TLDR_LOWER" | grep -qiE 'deploy|Deploy\.Rpm'; then
    STATUS_EMOJI=":rocket:"
elif echo "$_SN_LOWER $_TLDR_LOWER" | grep -qiE 'fix|bug'; then
    STATUS_EMOJI=":lady_beetle:"
elif echo "$_SN_LOWER $_TLDR_LOWER" | grep -qiE 'build|PR-[0-9]|monitor'; then
    STATUS_EMOJI=":building_construction:"
elif echo "$_TLDR_LOWER" | grep -qiE 'created \*\[|^created.*IT-'; then
    STATUS_EMOJI=":ticket:"
elif echo "$_TLDR_LOWER" | grep -qiE 'progress updated|progress file'; then
    STATUS_EMOJI=":clipboard:"
elif echo "$_CWD_LOWER" | grep -q 'metal_hobby_app'; then
    STATUS_EMOJI=":iphone:"
elif echo "$_CWD_LOWER" | grep -q 'wakelite'; then
    STATUS_EMOJI=":zap:"
elif echo "$_CWD_LOWER" | grep -q 'ad-refresh'; then
    STATUS_EMOJI=":arrows_counterclockwise:"
fi

# Header section: session name as clickable link (or bold if no link)
if [[ -n "$FOCUS_LINK" ]]; then
    HEADER_TEXT="${STATUS_EMOJI}  <${FOCUS_LINK}|${SESSION_NAME}>"
else
    HEADER_TEXT="${STATUS_EMOJI}  *${SESSION_NAME}*"
fi

# Context line: tab, duration, cwd
CONTEXT_PARTS=""
[[ -n "$LOCATION" ]] && CONTEXT_PARTS="${CONTEXT_PARTS}:desktop_computer: ${LOCATION}  "
CONTEXT_PARTS="${CONTEXT_PARTS}:stopwatch: ${DURATION_DISPLAY}  "
[[ -n "$SHORT_CWD" ]] && CONTEXT_PARTS="${CONTEXT_PARTS}:file_folder: \`${SHORT_CWD}\`"

# Build blocks JSON
BLOCKS=$(jq -n \
    --arg header "$HEADER_TEXT" \
    --arg context "$CONTEXT_PARTS" \
    --arg body "$FULL_BODY" \
    '[
        {
            "type": "section",
            "text": { "type": "mrkdwn", "text": $header }
        },
        {
            "type": "context",
            "elements": [
                { "type": "mrkdwn", "text": $context }
            ]
        },
        { "type": "divider" },
        {
            "type": "section",
            "text": { "type": "mrkdwn", "text": $body }
        }
    ]')

# Fallback text for push notifications / mobile (short TLDR)
FALLBACK_TEXT="${SESSION_NAME} — ${TLDR}"

# ── Per-tab-per-day thread support ──
# Each terminal tab gets its own Slack thread per day.
# Thread key: terminal_id (Ghostty/WezTerm) or SESSION_ID (fallback).
# Parent message updates via chat.update when session name or tab index changes.
# Set CDN_SESSION_THREAD=0 in ~/.claude-done-notify.env to disable.
SESSION_THREAD_ENABLED="${CDN_SESSION_THREAD:-1}"
SIGNAL_HUB_DIR="${HOME}/.signal-hub"

# Determine stable thread key.
# cmux: workspace+surface+session-scoped key (CC-95 audit fix). Two cmux sessions
#   that happen to share a surface_id would otherwise collide into one Slack
#   thread; the workspace prefix and session_id suffix make collisions impossible.
# ghostty/wezterm: terminal/pane id (one thread per terminal tab, day-scoped).
# fallback: session_id alone.
THREAD_KEY=""
if [[ "$TERMINAL_MODE" == "cmux" && -n "$MY_WORKSPACE_ID" && -n "$MY_PANE_ID" ]]; then
    THREAD_KEY="cmux:${MY_WORKSPACE_ID}:${MY_PANE_ID}:${SESSION_ID}"
elif [[ -n "$MY_PANE_ID" ]]; then
    THREAD_KEY="$MY_PANE_ID"
else
    THREAD_KEY="$SESSION_ID"
fi

# Helper: consistent emoji from THREAD_KEY (stable across /clear)
_thread_emoji() {
    local emojis hash_val c
    emojis=(🔵 🟢 🟠 🟣 🔴 🟡 ⚪ 🟤 💠 🔷 🔶 💎 🧊 🌀 🎯 🪐 🌸 🍀 🔥 ⚡ 🌊 🎪 🧿 🪩 🎲 🧩 🎭 🪄 🎸 🪘)
    hash_val=0
    for (( i=0; i<${#THREAD_KEY}; i++ )); do
        printf -v c '%d' "'${THREAD_KEY:$i:1}"
        hash_val=$(( (hash_val * 31 + c) % ${#emojis[@]} ))
    done
    echo "${emojis[$hash_val]}"
}

# Helper: build parent text from current state
_thread_parent_text() {
    local emoji tab_label
    emoji=$(_thread_emoji)
    if [[ -n "$TAB_NUMBER" ]]; then
        tab_label="Tab ${TAB_NUMBER} — "
    else
        tab_label=""
    fi
    echo "${emoji} ${tab_label}${SESSION_NAME}"
}

get_tab_thread_ts() {
    local today cache_file
    today=$(date +%Y-%m-%d)
    cache_file="${SIGNAL_HUB_DIR}/thread_${THREAD_KEY}_${today}.json"
    mkdir -p "$SIGNAL_HUB_DIR"

    # If thread exists for this tab today, check for drift and return ts
    if [[ -f "$cache_file" ]]; then
        local cached_ts cached_name cached_idx
        cached_ts=$(jq -r '.ts // empty' "$cache_file" 2>/dev/null)
        cached_name=$(jq -r '.name // empty' "$cache_file" 2>/dev/null)
        cached_idx=$(jq -r '.tab_index // empty' "$cache_file" 2>/dev/null)

        if [[ -n "$cached_ts" ]]; then
            # Detect drift: session name or tab index changed since last notification
            local drifted=0
            if [[ "$SESSION_NAME" != "$cached_name" ]]; then
                echo "$(date '+%H:%M:%S') THREAD: name drifted: '$cached_name' → '$SESSION_NAME'" >&2
                drifted=1
            fi
            if [[ -n "$TAB_NUMBER" && "$TAB_NUMBER" != "$cached_idx" ]]; then
                echo "$(date '+%H:%M:%S') THREAD: tab drifted: $cached_idx → $TAB_NUMBER" >&2
                drifted=1
            fi

            if [[ "$drifted" == "1" ]]; then
                local updated_text update_response update_ok
                updated_text=$(_thread_parent_text)

                update_response=$(curl -s -X POST "https://slack.com/api/chat.update" \
                    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
                    -H "Content-Type: application/json" \
                    -d "$(jq -n \
                        --arg channel "$SLACK_CHANNEL" \
                        --arg ts "$cached_ts" \
                        --arg text "$updated_text" \
                        '{channel: $channel, ts: $ts, text: $text}')")
                update_ok=$(echo "$update_response" | jq -r '.ok' 2>/dev/null)
                echo "$(date '+%H:%M:%S') THREAD: parent updated ok=$update_ok ('$updated_text')" >&2

                # Persist new metadata
                jq -n \
                    --arg ts "$cached_ts" \
                    --arg name "$SESSION_NAME" \
                    --arg tab_index "${TAB_NUMBER:-}" \
                    '{ts: $ts, name: $name, tab_index: $tab_index}' > "$cache_file"
            fi

            echo "$cached_ts"
            return 0
        fi
    fi

    # No thread for this tab today — create parent message
    local parent_text parent_response parent_ts
    parent_text=$(_thread_parent_text)

    parent_response=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg channel "$SLACK_CHANNEL" \
            --arg text "$parent_text" \
            '{channel: $channel, text: $text, unfurl_links: false}')")

    parent_ts=$(echo "$parent_response" | jq -r '.ts // empty' 2>/dev/null)
    if [[ -n "$parent_ts" ]]; then
        jq -n \
            --arg ts "$parent_ts" \
            --arg name "$SESSION_NAME" \
            --arg tab_index "${TAB_NUMBER:-}" \
            '{ts: $ts, name: $name, tab_index: $tab_index}' > "$cache_file"
        echo "$(date '+%H:%M:%S') THREAD: created thread $parent_ts for $THREAD_KEY ($SESSION_NAME) on $today" >&2
        echo "$parent_ts"
        return 0
    else
        echo "$(date '+%H:%M:%S') THREAD: failed: $(echo "$parent_response" | jq -r '.error // "unknown"')" >&2
        return 1
    fi
}

THREAD_TS=""
if [[ "$SESSION_THREAD_ENABLED" == "1" ]]; then
    THREAD_TS=$(get_tab_thread_ts) || THREAD_TS=""
    echo "$(date '+%H:%M:%S') THREAD: key=$THREAD_KEY ts=$THREAD_TS" >&2
fi

# ── Send Slack message ──
if [[ -n "$SLACK_BOT_TOKEN" && "$SLACK_BOT_TOKEN" != "null" ]]; then
    PAYLOAD=$(jq -n \
        --arg channel "$SLACK_CHANNEL" \
        --arg text "$FALLBACK_TEXT" \
        --argjson blocks "$BLOCKS" \
        --arg thread_ts "$THREAD_TS" \
        'if $thread_ts != "" then
            {channel: $channel, text: $text, blocks: $blocks, thread_ts: $thread_ts, unfurl_links: false, unfurl_media: false}
        else
            {channel: $channel, text: $text, blocks: $blocks, unfurl_links: false, unfurl_media: false}
        end')

    RESPONSE=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    OK=$(echo "$RESPONSE" | jq -r '.ok' 2>/dev/null)
    echo "$(date '+%H:%M:%S') SENT: ok=$OK session=$SESSION_NAME thread=$THREAD_TS" >&2
    if [[ "$OK" != "true" ]]; then
        echo "$(date '+%H:%M:%S') ERROR: $(echo "$RESPONSE" | jq -r '.error // "unknown"' 2>/dev/null)" >&2
    fi

    # Record notification timestamp for rate limiting
    echo "$(date +%s)" > "$LAST_NOTIFIED_FILE"
else
    echo "$(date '+%H:%M:%S') ERROR: no slack token" >&2
fi

exit 0
