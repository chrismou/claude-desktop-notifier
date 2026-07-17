#!/usr/bin/env bash
# claude-attention-hook.sh — Claude Code Notification hook
# Reads hook JSON from stdin, emits a native desktop notification.
# Supports Linux (notify-send / libnotify) and macOS (osascript / Notification Center).
# No background process; the emitter returns immediately.

set -euo pipefail

# ── Tunables ────────────────────────────────────────────────────────────────
# NOTE: URGENCY applies to Linux only.  On macOS, Notification Center has no
# urgency/persistence knob (without terminal-notifier, which is out of scope).
# The value is silently ignored on macOS — do not try to map it to anything
# there; there is no supported equivalent.
#
# Override via the CLAUDE_NOTIFY_URGENCY environment variable (set it in
# ~/.claude/settings.json "env" block so it reaches the hook on BOTH the
# standalone and plugin install channels and survives plugin updates):
#   { "env": { "CLAUDE_NOTIFY_URGENCY": "normal" } }
# Accepted values: "critical" (persists until dismissed) | "normal" (auto-expires).
URGENCY="${CLAUDE_NOTIFY_URGENCY:-critical}"
APP_NAME="Claude Code"
TITLE_SUFFIX="needs attention"           # title is "<project> <suffix>" when a project label is derived
FALLBACK_TITLE="Claude needs attention"  # title when no project label can be derived (jq absent, cwd missing)
# ────────────────────────────────────────────────────────────────────────────

# Validate URGENCY: whitelist to critical|normal; anything else falls back to critical.
# This prevents a typo from silently killing notifications (an invalid -u value
# makes notify-send error, which would be swallowed by || true → no notification).
case "$URGENCY" in
    critical|normal) : ;;
    *) echo "claude-attention-hook.sh: unknown CLAUDE_NOTIFY_URGENCY='$URGENCY', using 'critical'" >&2
       URGENCY="critical" ;;
esac

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

# Defaults — overridden below when jq can parse the payload.
project=""   # empty = no project label derived → fallback title
message=""   # empty = no message text → empty notification body
cwd=""       # empty = jq absent or cwd missing; pre-init so emit_linux reads safely under set -u

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
    # cwd drives the project label in the title; message becomes the body
    # (e.g. "Claude needs your permission to use Bash").
    cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""')" || cwd=""
    message="$(printf '%s' "$payload" | jq -r '.message // ""')" || message=""

    # Derive a friendly project label from cwd.
    #   1. basename of cwd   (the common case)
    #   2. full cwd          (if basename somehow came out empty, e.g. cwd is "/")
    #   3. no label          (if cwd itself is absent/empty — fallback title below)
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

# Build title and body.  The title LEADS with the project label
# ("<project> needs attention") because notification titles truncate at
# roughly 30-40 chars on both GNOME and macOS — project-first means
# truncation eats the boilerplate, never the label.  The label is
# load-bearing when multiple sessions run in parallel — it tells the user
# which terminal to switch to.  When no label could be derived (jq absent,
# or cwd missing/empty) fall back to a static title.
# The body is the hook's message text (why attention is needed); it may be
# empty (message missing, or jq absent) — both emitters accept an empty body.
if [ -n "$project" ]; then
    title="${project} ${TITLE_SUFFIX}"
else
    title="$FALLBACK_TITLE"
fi
body="$message"

# ── Emitters ────────────────────────────────────────────────────────────────

emit_linux() {
    # Linux: emit via notify-send (libnotify → GNOME Shell / notification daemon).
    # Build args once with set -- to avoid an icon × tier branch explosion.

    set -- -u "$URGENCY" -a "$APP_NAME"
    [ -f "$ICON" ] && set -- "$@" -i "$ICON"

    # ── Dedup: one active notification per project ───────────────────────────
    # Replace-by-id (libnotify >= 0.8.0) gives true notification-center dedup
    # across daemons (GNOME, KDE, dunst, mako).  There is NO reliable dedup on
    # older libnotify: GNOME Shell does not honour the x-canonical-private-
    # synchronous hint for notification-center replacement (verified on GNOME
    # Shell 42 — both notifications stack), so on libnotify < 0.8.0 we emit
    # plainly and notifications stack (unchanged, pre-feature behavior).
    tier=0            # 0 = plain emit (no dedup); set to 1 iff replaces_id exists
    id_file=""
    prev_id=""

    # Feature-detect --replace-id / --print-id FIRST, and only set up dedup state
    # when it can actually be used — so systems without replaces_id support leave
    # no empty state dir behind.  The grep runs inside an 'if' so its non-zero
    # exit under set -e/pipefail cannot abort the function.  Skip entirely when
    # cwd is empty (jq absent, or cwd missing): keying on an empty/constant
    # string would make all project-less notifications replace each other.
    if [ -n "$cwd" ]; then
        help_out="$(notify-send --help 2>&1 || true)"
        if printf '%s' "$help_out" | grep -q -- '--replace-id' \
           && printf '%s' "$help_out" | grep -q -- '--print-id'; then
            # Tier 1: spec-compliant replaces_id — works on GNOME, KDE, dunst, mako.
            tier=1

            # Dedup is keyed on the FULL ABSOLUTE cwd (hashed), not the basename,
            # so the same basename in different locations gets distinct slots.
            # cksum is POSIX and universally present on Linux; no new dependency.
            # Strip the byte-count field, leaving only the checksum digits.
            cksum_out="$(printf '%s' "$cwd" | cksum)"
            key="${cksum_out%% *}"

            # State dir: XDG_RUNTIME_DIR is per-user 0700 (preferred).
            # /tmp fallback is uid-suffixed to prevent cross-user pre-creation on
            # a shared host (XDG_RUNTIME_DIR is already per-user; /tmp is not).
            if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
                STATE_DIR="${XDG_RUNTIME_DIR}/claude-notifier"
            else
                STATE_DIR="/tmp/claude-notifier-$(id -u)"
            fi
            mkdir -p "$STATE_DIR" 2>/dev/null || true
            # Guard: on shared /tmp, another user may have pre-created this path
            # or planted a symlink. [ -O ] follows symlinks and tests effective
            # ownership. If the dir is not ours, leave id_file empty so dedup
            # degrades to plain emit.
            if [ -O "$STATE_DIR" ]; then
                id_file="${STATE_DIR}/${key}"
            fi

            prev_id="$([ -n "$id_file" ] && cat "$id_file" 2>/dev/null || true)"
            # Accept only a positive integer; discard stale or garbage content.
            case "$prev_id" in ''|*[!0-9]*) prev_id="" ;; esac
        fi
    fi

    # ── Emit ─────────────────────────────────────────────────────────────────
    # Use -- before positional args so a title/body starting with '-' is not
    # parsed as an option.
    if [ "$tier" = 1 ]; then
        # Tier 1: request a printed id (-p) and replace the previous one (-r).
        set -- "$@" -p
        [ -n "$prev_id" ] && set -- "$@" -r "$prev_id"
        set -- "$@" -- "$title" "$body"
        new_id="$(notify-send "$@" 2>/dev/null || true)"
        # Persist the new id only if it looks like a positive integer.
        # State write is AFTER the emit so a write failure never suppresses
        # the notification.
        case "$new_id" in
            ''|*[!0-9]*) : ;;
            *) [ -n "$id_file" ] && { printf '%s' "$new_id" > "$id_file"; } 2>/dev/null || true ;;
        esac
    else
        # Plain emit — no dedup. libnotify < 0.8.0 (any desktop, including GNOME
        # Shell, whose daemon does not honour x-canonical-private-synchronous for
        # notification-center dedup). Notifications stack, as before.
        set -- "$@" -- "$title" "$body"
        notify-send "$@"
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
    osascript - "$body" "$title" <<'APPLESCRIPT'
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
