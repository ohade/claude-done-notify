# claude-done-notify

Slack notifications when [Claude Code](https://docs.anthropic.com/en/docs/claude-code) finishes a turn and you're not looking at the terminal.

## What it does

A [Claude Code hook](https://docs.anthropic.com/en/docs/claude-code/hooks) that sends a Slack message when:

- Claude finishes responding (Stop event)
- The turn took longer than a configurable threshold (default: 10s)
- You're not currently looking at the terminal pane

### Features

- **Smart focus detection** (macOS + WezTerm): skips the notification if you're looking at the exact terminal pane where Claude is running
- **Rate limiting**: max one notification per 60s per session (configurable)
- **Session context**: message includes the session name and a summary of Claude's response
- **Minimal dependencies**: bash, curl, jq

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI with hooks support
- A Slack bot token with `chat:write` scope ([create one](https://api.slack.com/apps))
- `jq` and `curl`
- macOS recommended (for focus detection via `osascript`); works on Linux without focus detection
- [WezTerm](https://wezfurlong.org/wezterm/) optional, for pane-level focus detection

## Quick start

```bash
git clone https://github.com/ohade/claude-done-notify.git ~/claude-done-notify
cd ~/claude-done-notify
./install.sh
```

The installer will:
1. Prompt for your Slack bot token and channel ID
2. Write a config file at `~/.claude-done-notify.env`
3. Print the hook JSON to add to `~/.claude/settings.json`

## Manual setup

### 1. Create config file

Copy the example and fill in your values:

```bash
cp config.example.env ~/.claude-done-notify.env
chmod 600 ~/.claude-done-notify.env
```

Edit `~/.claude-done-notify.env`:

```bash
SLACK_BOT_TOKEN="xoxb-your-token-here"
SLACK_CHANNEL="D01234ABCDE"
```

### 2. Register hooks

Add to your `~/.claude/settings.json` (merge into existing `hooks` if you have them):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/claude-done-notify/claude-done-notify.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/claude-done-notify/claude-done-notify.sh",
            "timeout": 15000
          }
        ]
      }
    ]
  }
}
```

### 3. Test

Start a new Claude Code session, ask something that takes >10 seconds, switch away from the terminal, and check Slack.

## Configuration

All config is via environment variables. Set them in `~/.claude-done-notify.env` or export them in your shell profile.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SLACK_BOT_TOKEN` | Yes | — | Slack bot OAuth token (`xoxb-...`) |
| `SLACK_CHANNEL` | Yes | — | Slack channel or DM ID to notify |
| `CDN_MIN_DURATION` | No | `10` | Minimum turn duration (seconds) before notifying |
| `CDN_COOLDOWN` | No | `60` | Rate limit between notifications per session (seconds) |
| `CDN_FOCUS_DELAY` | No | `2` | Seconds to wait before checking focus |
| `CDN_TERMINAL` | No | `auto` | Terminal mode: `auto`, `wezterm`, `generic`, `none` |
| `CDN_SIGNALS_DIR` | No | `~/.claude/session-signals` | Directory for rate-limit marker files |
| `CDN_LOG_FILE` | No | `~/.claude/hooks/debug-claude-done-notify.log` | Debug log path |
| `CDN_CONFIG_FILE` | No | `~/.claude-done-notify.env` | Override config file location |

## How it works

The hook uses a two-phase approach tied to Claude Code's lifecycle events:

1. **UserPromptSubmit** — records a start timestamp for this turn
2. **Stop** — evaluates the filter chain and sends a notification if all gates pass

### Filter chain (Stop event)

```
Duration gate → Rate limit → Focus delay → Focus detection → Send
```

1. **Duration gate**: Was the turn longer than `CDN_MIN_DURATION`? Short interactions (quick questions) are skipped.
2. **Rate limit**: Has a notification been sent for this session in the last `CDN_COOLDOWN` seconds?
3. **Focus delay**: Wait `CDN_FOCUS_DELAY` seconds to avoid a race condition where the user switches back to the terminal right as Claude finishes.
4. **Focus detection**: Is the user currently looking at this terminal pane?

### Focus detection

On **macOS with WezTerm**, the hook does pane-level detection:
- Uses `osascript` to check which app is frontmost
- If WezTerm is focused, uses `wezterm cli list` + `list-clients` to check if the user is on the exact pane running this session
- Notifies if WezTerm is focused but on a *different* tab/pane

On **macOS with other terminals**, it does app-level detection:
- Skips notification if any terminal app (iTerm2, Terminal.app, Alacritty, Kitty) is frontmost

On **Linux** or with `CDN_TERMINAL=none`:
- No focus detection; always notifies if other gates pass

### Message format

```
*Session Name*  ·  Tab 3: pane title

Summary of Claude's last response (up to 300 chars)...
```

The session name comes from (in priority order):
1. Custom session title (set via `/rename` in Claude Code)
2. First prompt of the session (truncated)
3. WezTerm pane title
4. "Claude session" fallback

## Troubleshooting

**No notifications arriving:**
```bash
# Check the debug log
tail -30 ~/.claude/hooks/debug-claude-done-notify.log

# Verify your token works
source ~/.claude-done-notify.env
curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" https://slack.com/api/auth.test | jq .

# Verify channel access
curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"channel\":\"$SLACK_CHANNEL\",\"text\":\"test\"}" \
  https://slack.com/api/chat.postMessage | jq .
```

**Getting notified too often:**
- Increase `CDN_MIN_DURATION` (e.g., `30` for only long turns)
- Increase `CDN_COOLDOWN` (e.g., `120` for 2-minute cooldown)

**Getting notified even when looking at terminal:**
- Check `CDN_TERMINAL` setting — try `wezterm` explicitly if using WezTerm
- The debug log shows focus detection decisions (look for `FOCUS:` and `SKIP:` lines)

## Creating a Slack bot

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and create a new app
2. Under **OAuth & Permissions**, add the `chat:write` scope
3. Install the app to your workspace
4. Copy the **Bot User OAuth Token** (`xoxb-...`)
5. To find your DM channel ID: open Slack in a browser, click on the DM conversation — the channel ID is in the URL

## License

MIT
