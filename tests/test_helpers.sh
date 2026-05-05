#!/usr/bin/env bash
# CC-97: unit + regression tests for detect_terminal_mode + build_focus_link
# helpers in claude-done-notify.sh.
#
# Strategy: extract the helpers section into a temp file (between the markers
# "# ── Terminal helpers (CC-97) ──" and "# ── Read hook input from stdin ──"),
# source it, then exercise both functions with controlled env.
#
# Exit code: 0 on all-pass, 1 on any failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SOURCE="$REPO_DIR/claude-done-notify.sh"

if [[ ! -f "$SOURCE" ]]; then
    echo "ERR: cannot find $SOURCE" >&2
    exit 2
fi

HELPERS_TMP=$(mktemp -t cdn-helpers-XXXXXX)
CMUX_RUNTIME_TMP=$(mktemp -t cdn-cmux-runtime-XXXXXX)
trap 'rm -f "$HELPERS_TMP" "$CMUX_RUNTIME_TMP"' EXIT

awk '
    /^# ── Terminal helpers \(CC-97\) ──/ { in_block=1 }
    /^# ── Read hook input from stdin ──/ { in_block=0 }
    in_block { print }
' "$SOURCE" > "$HELPERS_TMP"

awk '
    /^# ── cmux runtime identity \(CC-64D\) ──/ { in_block=1 }
    /^# ── WezTerm runtime identity ──/ { in_block=0 }
    in_block { print }
' "$SOURCE" > "$CMUX_RUNTIME_TMP"

if ! grep -q '^detect_terminal_mode()' "$HELPERS_TMP" || \
   ! grep -q '^build_focus_link()' "$HELPERS_TMP"; then
    echo "ERR: helpers extraction failed (markers missing or moved)" >&2
    exit 2
fi

if ! grep -q 'MY_WORKSPACE_ID="${CMUX_WORKSPACE_ID:-}"' "$CMUX_RUNTIME_TMP" || \
   ! grep -q 'MY_PANE_ID="${CMUX_SURFACE_ID:-${CMUX_PANEL_ID:-}}"' "$CMUX_RUNTIME_TMP"; then
    echo "ERR: cmux runtime extraction failed (markers missing or moved)" >&2
    exit 2
fi

# shellcheck disable=SC1090
. "$HELPERS_TMP"

PASS=0
FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        printf 'FAIL: %s\n' "$name"
        printf '  expected: <<<%s>>>\n' "$expected"
        printf '  actual:   <<<%s>>>\n' "$actual"
    fi
}

clean_env() {
    unset CDN_TERMINAL CMUX_SURFACE_ID CMUX_PANEL_ID GHOSTTY_TERMINAL_ID \
          CMUX_WORKSPACE_ID CMUX_BUNDLED_CLI_PATH \
          CDN_CMUX_FOCUS_PORT CDN_CMUX_FOCUS_TOKEN_FILE \
          CDN_GHOSTTY_FOCUS_PORT CDN_FOCUS_PORT
}

# ════════════════════════════════════════════════════════════════════
# detect_terminal_mode — unit tests
# ════════════════════════════════════════════════════════════════════
clean_env

assert_eq "detect: cmux by CMUX_SURFACE_ID" "cmux" \
    "$(CMUX_SURFACE_ID=s1 detect_terminal_mode)"

assert_eq "detect: cmux by CMUX_PANEL_ID" "cmux" \
    "$(CMUX_PANEL_ID=p1 detect_terminal_mode)"

assert_eq "detect: ghostty by GHOSTTY_TERMINAL_ID" "ghostty" \
    "$(GHOSTTY_TERMINAL_ID=g1 detect_terminal_mode)"

assert_eq "detect: cmux beats ghostty (precedence)" "cmux" \
    "$(CMUX_SURFACE_ID=s1 GHOSTTY_TERMINAL_ID=g1 detect_terminal_mode)"

assert_eq "detect: CDN_TERMINAL override beats cmux env" "ghostty" \
    "$(CDN_TERMINAL=ghostty CMUX_SURFACE_ID=s1 detect_terminal_mode)"

assert_eq "detect: CDN_TERMINAL=auto means autodetect" "ghostty" \
    "$(CDN_TERMINAL=auto GHOSTTY_TERMINAL_ID=g1 detect_terminal_mode)"

assert_eq "detect: CDN_TERMINAL with custom value passes through" "myterm" \
    "$(CDN_TERMINAL=myterm detect_terminal_mode)"

# generic / wezterm depend on `command -v wezterm` — controlled via PATH in subshell.
GENERIC_RESULT=$(env -i PATH=/nonexistent HOME="$HOME" /bin/bash -c "
    source '$HELPERS_TMP'
    detect_terminal_mode
")
assert_eq "detect: generic when no env + no wezterm on PATH" "generic" "$GENERIC_RESULT"

FAKE_WEZTERM_DIR=$(mktemp -d -t cdn-fake-wezterm-XXXXXX)
cat > "$FAKE_WEZTERM_DIR/wezterm" <<'EOF'
#!/bin/sh
echo fake
EOF
chmod +x "$FAKE_WEZTERM_DIR/wezterm"
WEZTERM_RESULT=$(env -i PATH="$FAKE_WEZTERM_DIR" HOME="$HOME" /bin/bash -c "
    source '$HELPERS_TMP'
    detect_terminal_mode
")
assert_eq "detect: wezterm when found on PATH" "wezterm" "$WEZTERM_RESULT"
rm -rf "$FAKE_WEZTERM_DIR"

# ════════════════════════════════════════════════════════════════════
# build_focus_link — unit tests
# ════════════════════════════════════════════════════════════════════
clean_env

assert_eq "build: empty id → empty" "" \
    "$(build_focus_link ghostty "")"

assert_eq "build: ghostty default port" \
    "http://127.0.0.1:17381/focus?pane=g1" \
    "$(build_focus_link ghostty g1)"

assert_eq "build: ghostty custom port from env" \
    "http://127.0.0.1:11111/focus?pane=g1" \
    "$(CDN_GHOSTTY_FOCUS_PORT=11111 build_focus_link ghostty g1)"

assert_eq "build: wezterm default port" \
    "http://127.0.0.1:17380/focus?pane=w1" \
    "$(build_focus_link wezterm w1)"

assert_eq "build: wezterm custom port from env" \
    "http://127.0.0.1:22222/focus?pane=w1" \
    "$(CDN_FOCUS_PORT=22222 build_focus_link wezterm w1)"

assert_eq "build: generic → empty" "" \
    "$(build_focus_link generic anything)"

assert_eq "build: unknown type → empty" "" \
    "$(build_focus_link xterm anything)"

# cmux dispatch
TOKEN_FILE=$(mktemp -t cdn-token-XXXXXX)
echo "tok123" > "$TOKEN_FILE"

assert_eq "build: cmux without workspace (extra) → empty" "" \
    "$(CDN_CMUX_FOCUS_TOKEN_FILE=$TOKEN_FILE build_focus_link cmux surf1)"

assert_eq "build: cmux token present but missing workspace → empty" "" \
    "$(CDN_CMUX_FOCUS_TOKEN_FILE=$TOKEN_FILE build_focus_link cmux surface-ok "")"

assert_eq "build: cmux without token file → empty" "" \
    "$(CDN_CMUX_FOCUS_TOKEN_FILE=/nonexistent build_focus_link cmux surf1 ws1)"

assert_eq "build: cmux missing token file → empty link" "" \
    "$(CDN_CMUX_FOCUS_TOKEN_FILE=/tmp/cdn-token-does-not-exist build_focus_link cmux surface-ok workspace-ok)"

EMPTY_TOKEN_FILE=$(mktemp -t cdn-empty-token-XXXXXX)
: > "$EMPTY_TOKEN_FILE"
assert_eq "build: cmux with empty token file → empty" "" \
    "$(CDN_CMUX_FOCUS_TOKEN_FILE=$EMPTY_TOKEN_FILE build_focus_link cmux surf1 ws1)"
rm -f "$EMPTY_TOKEN_FILE"

assert_eq "build: cmux full URL (token + workspace)" \
    "http://127.0.0.1:17382/focus?token=tok123&workspace=ws1&surface=surf1" \
    "$(CDN_CMUX_FOCUS_TOKEN_FILE=$TOKEN_FILE build_focus_link cmux surf1 ws1)"

assert_eq "build: cmux valid token + valid workspace/surface" \
    "http://127.0.0.1:17382/focus?token=tok123&workspace=workspace-ok&surface=surface-ok" \
    "$(CDN_CMUX_FOCUS_TOKEN_FILE=$TOKEN_FILE build_focus_link cmux surface-ok workspace-ok)"

assert_eq "build: cmux custom port" \
    "http://127.0.0.1:33333/focus?token=tok123&workspace=ws1&surface=surf1" \
    "$(CDN_CMUX_FOCUS_PORT=33333 CDN_CMUX_FOCUS_TOKEN_FILE=$TOKEN_FILE build_focus_link cmux surf1 ws1)"

assert_eq "build: cmux custom CDN_CMUX_FOCUS_PORT=11999" \
    "http://127.0.0.1:11999/focus?token=tok123&workspace=workspace-ok&surface=surface-ok" \
    "$(CDN_CMUX_FOCUS_PORT=11999 CDN_CMUX_FOCUS_TOKEN_FILE=$TOKEN_FILE build_focus_link cmux surface-ok workspace-ok)"

rm -f "$TOKEN_FILE"

# ════════════════════════════════════════════════════════════════════
# cmux runtime block — unit tests
# ════════════════════════════════════════════════════════════════════
clean_env

CMUX_RUNTIME_ENV_RESULT=$(env -i PATH=/bin:/usr/bin HOME="$HOME" \
    TERMINAL_MODE=cmux CMUX_SURFACE_ID=surface-77 CMUX_WORKSPACE_ID=workspace-77 \
    /bin/bash -c "
        PANE_TITLE=old-title
        MY_PANE_ID=old-pane
        MY_WORKSPACE_ID=old-workspace
        TAB_NUMBER=9
        source '$CMUX_RUNTIME_TMP'
        printf '%s|%s|%s|%s\n' \"\$MY_WORKSPACE_ID\" \"\$MY_PANE_ID\" \"\$PANE_TITLE\" \"\$TAB_NUMBER\"
    " 2>/dev/null)
assert_eq "runtime: cmux env populates workspace/surface" \
    "workspace-77|surface-77||" "$CMUX_RUNTIME_ENV_RESULT"

CMUX_RUNTIME_PANEL_RESULT=$(env -i PATH=/bin:/usr/bin HOME="$HOME" \
    TERMINAL_MODE=cmux CMUX_PANEL_ID=panel-88 CMUX_WORKSPACE_ID=workspace-88 \
    /bin/bash -c "
        PANE_TITLE=old-title
        MY_PANE_ID=old-pane
        MY_WORKSPACE_ID=old-workspace
        TAB_NUMBER=9
        source '$CMUX_RUNTIME_TMP'
        printf '%s|%s|%s|%s\n' \"\$MY_WORKSPACE_ID\" \"\$MY_PANE_ID\" \"\$PANE_TITLE\" \"\$TAB_NUMBER\"
    " 2>/dev/null)
assert_eq "runtime: cmux panel alias populates surface id" \
    "workspace-88|panel-88||" "$CMUX_RUNTIME_PANEL_RESULT"

# ════════════════════════════════════════════════════════════════════
# Regression: parity with pre-CC-97 inline logic
# Pre-refactor (HEAD~1) inline logic, lines 372-381:
#   FOCUS_LINK=""
#   if [[ -n "$MY_PANE_ID" ]]; then
#       if [[ "$TERMINAL_MODE" == "ghostty" ]]; then
#           FOCUS_PORT="${CDN_GHOSTTY_FOCUS_PORT:-17381}"
#       else
#           FOCUS_PORT="${CDN_FOCUS_PORT:-17380}"
#       fi
#       FOCUS_LINK="http://127.0.0.1:${FOCUS_PORT}/focus?pane=${MY_PANE_ID}"
#   fi
# Pre-refactor (HEAD~1) inline detection, lines 162-171:
#   TERMINAL_MODE="${CDN_TERMINAL:-auto}"
#   if [[ "$TERMINAL_MODE" == "auto" ]]; then
#       if [[ -n "$GHOSTTY_TERMINAL_ID" ]]; then TERMINAL_MODE="ghostty"
#       elif command -v wezterm &>/dev/null; then TERMINAL_MODE="wezterm"
#       else TERMINAL_MODE="generic"
#       fi
#   fi
# ════════════════════════════════════════════════════════════════════
clean_env

# These cases exercise the same env / id permutations a pre-CC-97 hook would
# encounter in production, and confirm the helper output matches the inline
# output byte-for-byte. The cmux row was NEW in CC-97 and is excluded from
# regression (it didn't exist pre-refactor).

assert_eq "regression: ghostty default URL matches old inline" \
    "http://127.0.0.1:17381/focus?pane=ABC" \
    "$(build_focus_link ghostty ABC)"

assert_eq "regression: wezterm default URL matches old inline" \
    "http://127.0.0.1:17380/focus?pane=XYZ" \
    "$(build_focus_link wezterm XYZ)"

assert_eq "regression: empty pane id → empty (matches old 'if -n MY_PANE_ID')" \
    "" \
    "$(build_focus_link ghostty "")"

assert_eq "regression: ghostty CDN_GHOSTTY_FOCUS_PORT honored (old default 17381)" \
    "http://127.0.0.1:55555/focus?pane=ABC" \
    "$(CDN_GHOSTTY_FOCUS_PORT=55555 build_focus_link ghostty ABC)"

assert_eq "regression: wezterm CDN_FOCUS_PORT honored (old default 17380)" \
    "http://127.0.0.1:55555/focus?pane=XYZ" \
    "$(CDN_FOCUS_PORT=55555 build_focus_link wezterm XYZ)"

# Detection regression
assert_eq "regression: ghostty by env (no CDN_TERMINAL override)" \
    "ghostty" \
    "$(GHOSTTY_TERMINAL_ID=g detect_terminal_mode)"

assert_eq "regression: CDN_TERMINAL custom value passes through (matches old)" \
    "myterm" \
    "$(CDN_TERMINAL=myterm detect_terminal_mode)"

assert_eq "regression: CDN_TERMINAL=auto + ghostty env (matches old auto branch)" \
    "ghostty" \
    "$(CDN_TERMINAL=auto GHOSTTY_TERMINAL_ID=g detect_terminal_mode)"

REG_GENERIC=$(env -i PATH=/nonexistent HOME="$HOME" /bin/bash -c "
    source '$HELPERS_TMP'
    detect_terminal_mode
")
assert_eq "regression: generic with no env + no wezterm (matches old 'else')" \
    "generic" "$REG_GENERIC"

# ════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════
TOTAL=$((PASS + FAIL))
echo
echo "═══════════════════════════════════════════════════════════════"
printf "Tests: %d total, %d pass, %d fail\n" "$TOTAL" "$PASS" "$FAIL"
echo "═══════════════════════════════════════════════════════════════"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
