#!/usr/bin/env bash
# claude-attention-hook.sh — Claude Code Notification hook
# Reads hook JSON from stdin, emits a native desktop notification.
# Supports Linux (notify-send / libnotify) and macOS (osascript / Notification Center).
# No background process; the emitter returns immediately.

set -euo pipefail

# ── Tunables ────────────────────────────────────────────────────────────────
# NOTE: URGENCY applies to Linux only.  On macOS, Notification Center has no
# urgency/persistence knob (without terminal-notifier, which is out of scope).
# The value below is silently ignored on macOS — do not try to map it to
# anything there; there is no supported equivalent.
URGENCY="critical"   # Linux: "critical" = persists in tray until dismissed
                     # Linux: "normal"   = auto-expires after a few seconds
APP_NAME="Claude Code"
TITLE="Claude needs attention"
# ────────────────────────────────────────────────────────────────────────────

# ── Script-directory resolution ──────────────────────────────────────────────
# Resolves the real directory of this script so that sibling assets (e.g. the
# Claude icon at ../assets/claude-icon.svg) are found regardless of the
# directory name or cwd when the hook is invoked.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICON="${SCRIPT_DIR}/../assets/claude-icon.svg"

# ── OS detection (computed once) ────────────────────────────────────────────
os="$(uname -s)"

# ── Shared parse / build (OS-agnostic) ──────────────────────────────────────

# Read the full JSON payload Claude Code writes to stdin.
payload="$(cat)"

# Guard: empty stdin — nothing useful to act on; exit 0 so Claude is never blocked.
if [ -z "$payload" ]; then
    echo "claude-attention-hook.sh: empty stdin, skipping" >&2
    exit 0
fi

# Default project label — used when jq is absent or cwd is missing/empty.
project="unknown project"

# Detect jq availability once.  Standalone installs pass install.sh's preflight
# (jq required), so jq is normally present.  Plugin installs have no preflight —
# if jq is missing, degrade gracefully rather than dropping the event silently.
if command -v jq >/dev/null 2>&1; then

    # Guard: validate the payload is a JSON object.  Non-object JSON (arrays,
    # strings, truncated data) means there is nothing useful to act on — warn
    # and exit cleanly so the hook never blocks Claude.
    if ! printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
        echo "claude-attention-hook.sh: unparseable hook payload, skipping" >&2
        exit 0
    fi

    # Extract fields with jq (-r for raw strings, empty string on missing/null).
    # Only cwd is shown; the notification body is intentionally just the project
    # name (the title already says "Claude needs attention"), so message is unused.
    cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""')" || cwd=""

    # Derive a friendly project label from cwd.
    #   1. basename of cwd   (the common case)
    #   2. full cwd          (if basename somehow came out empty, e.g. cwd is "/")
    #   3. generic fallback  (if cwd itself is absent/empty — uses default above)
    # Use bash parameter expansion (${cwd##*/}) rather than `basename` — the GNU
    # `basename -- "$cwd"` idiom is NOT portable: BSD basename on macOS treats `--`
    # as the string argument and would emit a literal "--". Parameter expansion is
    # bash-3.2 safe, needs no fork, and has no `--` ambiguity.
    if [ -n "$cwd" ]; then
        # Strip a trailing slash (except for the root "/") so a cwd like
        # "/home/x/foo/" still yields "foo" rather than the whole path.
        [ "$cwd" != "/" ] && cwd="${cwd%/}"
        project="${cwd##*/}"
        if [ -z "$project" ]; then
            project="$cwd"
        fi
    fi

else
    # jq is not installed.  Warn via stderr (visible in `claude --debug` output)
    # and fall through to emit a generic notification.  Claude Code is never blocked.
    echo "claude-attention-hook.sh: jq not found — showing generic notification; install jq (apt install jq / brew install jq) to see project names" >&2
fi

# Build notification body: just the project label (no message text — the title
# already conveys "needs attention", so repeating it would be redundant).
# The project label is load-bearing when multiple sessions are running in
# parallel — it tells the user which terminal to switch to.
body="$project"

# ── Emitters ────────────────────────────────────────────────────────────────

emit_linux() {
    # Linux: emit via notify-send (libnotify -> GNOME Shell / notification daemon).
    # Use -- before positional args so a body starting with '-' is not parsed as
    # an option.  Title and body are separate argv elements — no eval, no command
    # string construction.
    # Pass the Claude icon (-i) only if the asset file exists alongside the script;
    # a missing icon file never breaks the notification.
    if [ -f "$ICON" ]; then
        notify-send \
            -u "$URGENCY" \
            -a "$APP_NAME" \
            -i "$ICON" \
            -- \
            "$TITLE" \
            "$body"
    else
        notify-send \
            -u "$URGENCY" \
            -a "$APP_NAME" \
            -- \
            "$TITLE" \
            "$body"
    fi
}

emit_macos() {
    # macOS: emit via built-in osascript -> Notification Center.
    # No third-party dependency (terminal-notifier is explicitly out of scope).
    # Notifications are attributed to "Script Editor" (the osascript host app) —
    # this is expected, not a bug; there is no supported way to change it without
    # a bundled .app.
    # Urgency is a no-op on macOS (see URGENCY tunable comment above).
    # Custom icon: osascript's 'display notification' has no icon parameter; a
    # custom app icon is not supported without a bundled .app (out of scope).
    #
    # SAFETY: the body/title are passed as AppleScript `argv`, NOT interpolated
    # into the script text. This is injection-proof for ANY content (quotes,
    # backslashes, newlines, AppleScript keywords) and avoids relying on the
    # undocumented `\"` escape behaviour of osascript's string literals.
    osascript - "$body" "$TITLE" <<'APPLESCRIPT'
on run argv
    display notification (item 1 of argv) with title (item 2 of argv)
end run
APPLESCRIPT
}

# ── OS dispatch ─────────────────────────────────────────────────────────────

case "$os" in
    Linux)
        # `|| true` so a failing emitter (no D-Bus session, daemon blocked,
        # binary missing at hook time) never propagates non-zero under `set -e`.
        emit_linux || true
        ;;
    Darwin)
        emit_macos || true
        ;;
    *)
        echo "claude-attention-hook.sh: unsupported OS '${os}' (Linux + macOS only)" >&2
        # Never hard-fail the hook — exit 0 so Claude Code continues normally.
        exit 0
        ;;
esac

exit 0
