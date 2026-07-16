#!/usr/bin/env bash
# install.sh — Install the Claude Code attention notifier (Linux + macOS).
# Merges the Notification hook into ~/.claude/settings.json, preserving all
# existing keys.  Idempotent: safe to run more than once.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="${REPO_DIR}/bin/claude-attention-hook.sh"
SETTINGS="${HOME}/.claude/settings.json"

# ── OS detection ──────────────────────────────────────────────────────────────

os="$(uname -s)"

# ── OS-aware preflight checks ─────────────────────────────────────────────────

echo "Checking dependencies (OS: ${os})..."

case "$os" in
    Linux)
        # Linux: require notify-send (libnotify-bin) and jq.
        if ! command -v notify-send >/dev/null 2>&1; then
            echo "ERROR: notify-send not found." >&2
            echo "  Install it with:  sudo apt install libnotify-bin" >&2
            exit 1
        fi
        echo "  notify-send: OK ($(command -v notify-send))"

        if ! command -v jq >/dev/null 2>&1; then
            echo "ERROR: jq not found." >&2
            echo "  Install it with:  sudo apt install jq" >&2
            exit 1
        fi
        echo "  jq: OK ($(command -v jq))"

        # Warn (don't hard-fail) if we cannot detect a notification daemon.
        # GNOME Shell provides one; this check is just a sanity hint.
        if ! command -v gdbus >/dev/null 2>&1 && ! pgrep -x gnome-shell >/dev/null 2>&1; then
            echo "WARNING: Could not confirm a running notification daemon." >&2
            echo "  Notifications may not appear if no daemon (e.g. GNOME Shell) is running." >&2
        fi
        ;;

    Darwin)
        # macOS: osascript is built-in (sanity check only); jq must be installed.
        if ! command -v osascript >/dev/null 2>&1; then
            echo "ERROR: osascript not found — this should not happen on macOS." >&2
            echo "  osascript ships with macOS. Check your PATH." >&2
            exit 1
        fi
        echo "  osascript: OK ($(command -v osascript))"

        if ! command -v jq >/dev/null 2>&1; then
            echo "ERROR: jq not found." >&2
            echo "  Install it with:  brew install jq" >&2
            exit 1
        fi
        echo "  jq: OK ($(command -v jq))"

        # Note: macOS notification permission for "Script Editor" (the osascript
        # host app) may be requested the first time a notification is posted.
        # This is handled by macOS automatically; no check needed here.
        ;;

    *)
        echo "ERROR: Unsupported OS '${os}' (Linux + macOS only)." >&2
        exit 1
        ;;
esac

# ── Make the hook script executable ──────────────────────────────────────────

chmod +x "$HOOK_SCRIPT"
echo "Made executable: $HOOK_SCRIPT"

# ── Merge hook config into ~/.claude/settings.json ───────────────────────────
# The following block is identical on Linux and macOS:
# ~/.claude/settings.json exists at the same path on both OSes.

# Ensure the settings file exists (Claude Code creates it, but just in case).
if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    echo '{}' > "$SETTINGS"
    echo "Created empty settings file: $SETTINGS"
fi

# Validate current JSON.
if ! jq empty "$SETTINGS" 2>/dev/null; then
    echo "ERROR: $SETTINGS is not valid JSON. Cannot merge safely." >&2
    exit 1
fi

# Back up before touching anything.
BACKUP="${SETTINGS}.bak.$(date +%Y%m%dT%H%M%S)"
cp "$SETTINGS" "$BACKUP"
echo "Backed up settings to: $BACKUP"

# Build the hook entry we want to be present.
# The command path is this repo's absolute path, baked in at install time.
NEW_HOOK_CMD="$HOOK_SCRIPT"

# jq merge strategy (idempotent):
#   1. Extract existing Notification hooks array (or empty array if absent).
#   2. Remove any entry whose hooks[].command already matches our script path
#      (handles re-runs without duplicating).
#   3. Append a fresh entry for our script.
#   4. Set .hooks.Notification to the resulting array.
#   5. Merge into the existing document so all other keys are preserved.
MERGED="$(jq \
    --arg cmd "$NEW_HOOK_CMD" \
    '
    # Current Notification array, or []
    (.hooks.Notification // []) as $existing |

    # Remove any previous entry that already points at our command
    ($existing | map(
        select(
            .hooks | map(.command) | any(. == $cmd) | not
        )
    )) as $pruned |

    # Append our entry
    ($pruned + [{
        "matcher": "",
        "hooks": [
            { "type": "command", "command": $cmd }
        ]
    }]) as $updated |

    # Write back, preserving all other top-level keys
    . * { "hooks": ((.hooks // {}) * { "Notification": $updated }) }
    ' \
    "$SETTINGS")"

# Write to a temp file then atomically move into place.
# Clean up the temp file on any early exit (e.g. disk full during the write).
TMP_SETTINGS="$(mktemp "${SETTINGS}.tmp.XXXXXX")"
trap 'rm -f "${TMP_SETTINGS:-}"' EXIT
printf '%s\n' "$MERGED" > "$TMP_SETTINGS"
mv "$TMP_SETTINGS" "$SETTINGS"

echo "Merged hook config into: $SETTINGS"

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "Installation complete."
echo ""
echo "Next steps:"
echo "  1. If Claude Code (claude) is already running, reload hooks with /hooks"
echo "     or restart the Claude Code session."
echo "  2. Test with:"
echo "     echo '{\"hook_event_name\":\"Notification\",\"message\":\"Claude needs your permission to use Bash\",\"cwd\":\"/home/user/dev/foo\"}' \\"
echo "       | ${HOOK_SCRIPT}"
echo "  3. To uninstall, run:  ${REPO_DIR}/uninstall.sh"
echo ""
echo "Note: this repo must remain at its current path."
echo "  If you move it, re-run install.sh from the new location."
