#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${HOME}/.claude-done-notify.env"
SIGNALS_DIR="${HOME}/.claude/session-signals"
HOOK_PATH="${SCRIPT_DIR}/claude-done-notify.sh"

echo "claude-done-notify installer"
echo "============================"
echo

# ── Step 1: Config file ──
SKIP_CONFIG=""
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Config file already exists: $CONFIG_FILE"
    read -p "Overwrite? [y/N] " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && SKIP_CONFIG=1 && echo "Keeping existing config."
fi

if [[ -z "$SKIP_CONFIG" ]]; then
    echo
    read -p "Slack Bot Token (xoxb-...): " TOKEN
    read -p "Slack Channel ID (e.g., D01234ABCDE): " CHANNEL
    echo

    cat > "$CONFIG_FILE" <<EOF
# claude-done-notify configuration
SLACK_BOT_TOKEN="${TOKEN}"
SLACK_CHANNEL="${CHANNEL}"

# Optional tuning (uncomment to override defaults)
# CDN_MIN_DURATION=10
# CDN_COOLDOWN=60
# CDN_FOCUS_DELAY=2
# CDN_TERMINAL=auto
EOF
    chmod 600 "$CONFIG_FILE"
    echo "Wrote $CONFIG_FILE (permissions: 600)"
fi

# ── Step 1b: cmux focus token bootstrap (CC-64D) ──
# Race-free creation: write inside a (umask 077) subshell so the file is never
# group/world-readable, even briefly. Then unconditionally re-assert chmod 600
# so existing tokens with wrong perms are corrected on every install run.
TOKEN_FILE="${HOME}/.cmux-focus-token"
if [[ ! -f "$TOKEN_FILE" ]]; then
    if command -v openssl &>/dev/null; then
        ( umask 077 && openssl rand -hex 32 > "$TOKEN_FILE" )
    else
        # Fallback for systems without openssl — /dev/urandom is universally available.
        ( umask 077 && head -c 32 /dev/urandom | xxd -p -c 64 > "$TOKEN_FILE" )
    fi
    echo "Wrote $TOKEN_FILE (cmux focus token, permissions: 600)"
else
    echo "cmux focus token already exists: $TOKEN_FILE (kept)"
fi
# Always chmod 600 — covers existing tokens with corrupted perms (CC-95 audit fix).
chmod 600 "$TOKEN_FILE"

# ── Step 2: Ensure directories ──
mkdir -p "$SIGNALS_DIR"
echo "Ensured signals directory: $SIGNALS_DIR"

# Hook log directory used by the cmux focus LaunchAgent (CC-95 audit fix:
# launchd silently drops StandardOut/Error if the directory does not exist).
HOOKS_LOG_DIR="${HOME}/.claude/hooks"
mkdir -p "$HOOKS_LOG_DIR"
echo "Ensured hooks log directory: $HOOKS_LOG_DIR"

# ── Step 2b: Render cmux focus LaunchAgent plist from template (CC-95 audit fix) ──
# The template carries placeholders so the plist works for any user/checkout
# layout instead of hardcoding /Users/ohad.e/... — that hardcode produced a
# permanent crash-loop for any other user, with KeepAlive=true respawning every
# 5s. We also detect python3 dynamically (no hardcoded /usr/bin/python3) and
# install.sh writes the rendered plist directly to ~/Library/LaunchAgents.
PLIST_TEMPLATE="${SCRIPT_DIR}/com.ohad.cmux-focus.plist.template"
PLIST_TARGET="${HOME}/Library/LaunchAgents/com.ohad.cmux-focus.plist"
if [[ -f "$PLIST_TEMPLATE" ]]; then
    PYTHON_BIN=$(command -v python3 || echo "/usr/bin/python3")
    mkdir -p "${HOME}/Library/LaunchAgents"
    sed \
        -e "s|__PYTHON__|${PYTHON_BIN}|g" \
        -e "s|__SCRIPT_DIR__|${SCRIPT_DIR}|g" \
        -e "s|__LOG_DIR__|${HOOKS_LOG_DIR}|g" \
        "$PLIST_TEMPLATE" > "$PLIST_TARGET"
    echo "Rendered LaunchAgent plist: $PLIST_TARGET"
    echo "  python: $PYTHON_BIN"
    echo "  script: ${SCRIPT_DIR}/cmux-focus-server.py"
fi

# ── Step 3: Make hook executable ──
chmod +x "$HOOK_PATH"
echo "Made hook executable: $HOOK_PATH"

# ── Step 4: Print settings.json snippet ──
echo
echo "───────────────────────────────────────────────────"
echo "Add the following hooks to your ~/.claude/settings.json."
echo "Merge into your existing \"hooks\" object if you already have one."
echo "───────────────────────────────────────────────────"
echo
cat <<JSONEOF
"hooks": {
  "UserPromptSubmit": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "${HOOK_PATH}"
        }
      ]
    }
  ],
  "Stop": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "${HOOK_PATH}",
          "timeout": 15000
        }
      ]
    }
  ]
}
JSONEOF
echo
echo "Done! Start a new Claude Code session to test."
echo "Debug log: ~/.claude/hooks/debug-claude-done-notify.log"
echo
echo "For Codex, add these as additional hooks to ~/.codex/hooks.json:"
echo
cat <<JSONEOF
"UserPromptSubmit": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "CDN_AGENT_NAME=Codex ${HOOK_PATH} UserPromptSubmit",
        "timeout": 5000
      }
    ]
  }
],
"Stop": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "CDN_AGENT_NAME=Codex ${HOOK_PATH} Stop",
        "timeout": 15000
      }
    ]
  }
]
JSONEOF
echo "After changing Codex hooks, restart Codex and run /hooks once to trust any new hook entries."
echo
echo "── cmux focus server (CC-64D) ──"
echo "Plist rendered to: ${HOME}/Library/LaunchAgents/com.ohad.cmux-focus.plist"
echo "Load with: launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.ohad.cmux-focus.plist"
echo "Smoke test: curl 'http://127.0.0.1:17382/health'"
echo "Disable per-session: export CMUX_FOCUS_DISABLE=1"
