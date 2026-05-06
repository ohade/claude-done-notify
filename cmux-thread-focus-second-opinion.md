# Issue 1 design: stale cmux Slack threads

## Diagnosis

Confirmed.

The Stop hook builds a cmux thread key as `cmux:${MY_WORKSPACE_ID}:${MY_PANE_ID}:${SESSION_ID}` in `claude-done-notify.sh:581-587`. `get_tab_thread_ts` then maps that key to one cache file per calendar day: `${SIGNAL_HUB_DIR}/thread_${THREAD_KEY}_${today}.json` in `claude-done-notify.sh:614-618`.

If that file exists and contains `.ts`, the function returns the same parent timestamp for the rest of the day. The only invalidation is parent metadata drift for session name or tab index in `claude-done-notify.sh:627-663`; there is no freshness check.

The log proves the UX failure:

- `01:21:36`: parent `1778019696.352909` was created for `cmux:A3B375EB-2336-4A5E-B423-02E43778053D:4D6466EA-C838-4570-A819-E3E2851AC183:c24235a9-c62f-4ef5-9ef4-d052befe27cd`.
- `08:01:15`: the same key reused `ts=1778019696.352909`.
- `08:07:55`: the same key again reused `ts=1778019696.352909`.

So a reply at 08:01/08:07 lands under a parent created at 01:21, which leaves the visible parent far down the Slack DM scrollback.

## Minimal-risk fix

Roll the thread when the cached thread has been idle for more than 4 hours. "Idle" should mean `last_reply_ts`, not parent creation time, so actively used sessions do not roll just because the first parent is old.

Add a config default near the other optional settings:

```bash
THREAD_FRESHNESS_SECONDS="${CDN_THREAD_FRESHNESS_SECONDS:-14400}"
```

Then change the thread cache schema from:

```json
{"ts":"1778019696.352909","name":"Claude session","tab_index":""}
```

to this backward-compatible shape:

```json
{
  "ts": "1778019696.352909",
  "name": "Claude session",
  "tab_index": "",
  "created_ts": 1778019696,
  "last_reply_ts": 1778045276
}
```

No filename change is needed. Existing caches can be migrated lazily: if `last_reply_ts` is absent, use `created_ts`; if both are absent, derive an epoch from the integer part of Slack `ts`. That makes old 01:21 cache files roll immediately once they are older than the threshold.

Precise `claude-done-notify.sh` change-set:

1. Add `_thread_cache_file` so `get_tab_thread_ts` and the later reply-success path update the same file.
2. In `get_tab_thread_ts`, read `cached_created` and `cached_last_reply` alongside `cached_ts`.
3. Before drift handling returns `cached_ts`, compute:

```bash
last_seen="${cached_last_reply:-${cached_created:-${cached_ts%%.*}}}"
age=$(( $(date +%s) - last_seen ))
```

If `last_seen` is numeric and `age > THREAD_FRESHNESS_SECONDS`, log `THREAD: stale age=${age}s threshold=${THREAD_FRESHNESS_SECONDS}s old_ts=$cached_ts; rolling`, skip the cached return, and fall through to the existing parent creation block.

4. When creating a parent in `claude-done-notify.sh:667-686`, write `created_ts` and `last_reply_ts` with `date +%s`.
5. When parent metadata drifts in `claude-done-notify.sh:639-660`, preserve `created_ts` and `last_reply_ts` instead of rewriting the cache back to the old three-field schema.
6. After the real Slack reply succeeds in `claude-done-notify.sh:719-726`, update `last_reply_ts` for the matching `THREAD_TS`. Guard the update with `.ts == $THREAD_TS` so a parallel Stop hook cannot overwrite a freshly rolled cache with an older thread.

Rollover behavior should be simple: create a new top-level parent via the existing parent creation block, overwrite the same cache file with the new parent, then send the actual notification as a threaded reply under that new parent. Do not add an at-mention and do not mutate old parents.

## Test strategy

Extend `tests/test_helpers.sh` with a new extraction block for `# -- Per-tab-per-day thread support --` through `# -- Send Slack message --`. Use a temp `SIGNAL_HUB_DIR` and a fake `curl` earlier on `PATH` that returns deterministic `{"ok":true,"ts":"2000.000001"}` for parent creation.

Add cases for:

- Fresh cache: `last_reply_ts=now-60` returns existing `ts` and does not call parent creation.
- Stale cache: `last_reply_ts=now-14401` creates a new parent and overwrites `ts`, `created_ts`, and `last_reply_ts`.
- Legacy stale cache: only `ts="<old_epoch>.000001"` rolls.
- Legacy fresh cache: only `ts="<recent_epoch>.000001"` reuses.
- Drift update preserves `created_ts` and `last_reply_ts`.
- Reply success updates `last_reply_ts` only when the cache `.ts` still matches the delivered `THREAD_TS`.

# Issue 2 design: missing focus link for DEV-219404

## Diagnosis

Confirmed.

The DEV-219404 Stop hook at `07:53:42` logged:

```text
PANE: pane= tab= title= (src=tty)
```

That line comes from the WezTerm branch in `claude-done-notify.sh:257-281`, not the cmux branch. The cmux branch would have logged `PANE: cmux ws=... surface=...` from `claude-done-notify.sh:241-253`.

So this subprocess did not receive `CMUX_SURFACE_ID`, `CMUX_PANEL_ID`, or `CMUX_WORKSPACE_ID`. It also did not have a useful Ghostty id, and the WezTerm TTY lookup produced no pane id. The result was:

- `MY_PANE_ID=""`, so `build_focus_link` returned an empty link at `claude-done-notify.sh:71-75`.
- `THREAD_KEY="$SESSION_ID"` via the fallback in `claude-done-notify.sh:584-587`.
- Slack still sent, but the header was not clickable and the thread was not cmux-scoped.

## Minimal-risk fix

Add a best-effort parent-process environment walk before terminal mode detection. This stays inside `claude-done-notify.sh` and does not require changing cmux-launch shell integration.

Precise `claude-done-notify.sh` change-set:

1. Add a helper near the terminal helpers:

```bash
detect_cmux_parent_env() {
    local pid="${1:-$PPID}" info ppid env_line ws sf i
    for i in 1 2 3 4 5 6 7 8; do
        env_line=$(ps eww -p "$pid" 2>/dev/null || true)
        ws=$(printf '%s\n' "$env_line" | tr ' ' '\n' | sed -n 's/^CMUX_WORKSPACE_ID=//p' | head -1)
        sf=$(printf '%s\n' "$env_line" | tr ' ' '\n' | sed -n 's/^CMUX_SURFACE_ID=//p; s/^CMUX_PANEL_ID=//p' | head -1)
        if [[ -n "$ws" && -n "$sf" ]]; then
            printf '%s|%s\n' "$ws" "$sf"
            return 0
        fi
        info=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ -z "$info" || "$info" == "0" ]] && break
        pid="$info"
    done
    return 1
}
```

2. Before `TERMINAL_MODE=$(detect_terminal_mode)` at `claude-done-notify.sh:238-239`, call the helper only when direct cmux env is absent. If it returns `workspace|surface`, assign `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` in the current shell, then let the existing `detect_terminal_mode` and cmux runtime block handle the rest.
3. Log a single diagnostic such as `PANE: cmux identity recovered from parent env ws=... surface=...`.
4. If the parent walk fails, keep the current send-without-focus-link behavior but log it explicitly when frontmost is cmux: `WARN: cmux frontmost but no cmux identity; focus link omitted`. Do not use `cmux identify .focused` as a substitute for this session's identity; that can point at the surface the user is currently viewing, not the surface that emitted this Stop hook.

The important safety property: only build a cmux focus link when the workspace and surface come from this process tree's environment. If there is no reliable session identity, sending without a focus link is the right clean exit.

## Test strategy

In `tests/test_helpers.sh`, add tests for the new helper with a fake `ps` on `PATH`:

- Current env has cmux ids: existing behavior remains unchanged.
- Direct env missing, parent env has both `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID`: mode becomes cmux and `build_focus_link cmux` returns the expected URL.
- Parent env has only workspace or only surface: no cmux mode recovery.
- Parent env has `CMUX_PANEL_ID` instead of `CMUX_SURFACE_ID`: recovered surface uses the panel alias.
- No parent env: behavior remains send-without-focus-link.

# Adversarial findings

## Third issue: Slack failure still starts cooldown

The current Stop path writes `${SESSION_ID}.last-notified` unconditionally after `chat.postMessage`, even when Slack returns `ok=false` in `claude-done-notify.sh:719-726`.

That means a transient Slack failure or rate limit can suppress the next retry for `CDN_COOLDOWN` seconds even though no user-visible notification was delivered. In the threaded path it is worse: `get_tab_thread_ts` may successfully create a parent, then the actual threaded reply can fail, leaving an empty parent plus a cooldown.

Minimal fix: move `echo "$(date +%s)" > "$LAST_NOTIFIED_FILE"` inside `if [[ "$OK" == "true" ]]`. Also only update the proposed `last_reply_ts` when `OK == "true"`. On failure, keep logging the Slack error and let the next Stop retry instead of cooling down a missing notification.

## Secondary race to keep in mind

Thread cache writes are non-atomic today. If two Stop hooks for the same `THREAD_KEY` pass cooldown close together, they can both observe a missing or stale cache and create duplicate parents. The low-risk mitigation is to write cache updates through `mktemp` plus `mv`, and guard reply timestamp updates with `.ts == $THREAD_TS`. A lock would be stronger, but the atomic-write plus compare guard is likely enough for this hook.
