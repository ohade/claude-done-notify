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

# ── Step 2: Ensure directories ──
mkdir -p "$SIGNALS_DIR"
echo "Ensured signals directory: $SIGNALS_DIR"

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
