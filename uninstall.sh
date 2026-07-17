#!/usr/bin/env bash
# uninstall.sh — Remove the Claude Code attention notifier hook (Linux + macOS).
# Removes only this repo's Notification hook entry from ~/.claude/settings.json,
# preserving all other settings.  Idempotent: safe to run more than once.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="${REPO_DIR}/bin/claude-attention-hook.sh"
SETTINGS="${HOME}/.claude/settings.json"

# ── Dependency check ─────────────────────────────────────────────────────────

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not found — required to safely edit settings.json." >&2
    exit 1
fi

# ── Validate settings file ───────────────────────────────────────────────────

if [ ! -f "$SETTINGS" ]; then
    echo "Nothing to do: $SETTINGS does not exist."
    exit 0
fi

if ! jq empty "$SETTINGS" 2>/dev/null; then
    echo "ERROR: $SETTINGS is not valid JSON. Cannot edit safely." >&2
    exit 1
fi

# ── Back up first ────────────────────────────────────────────────────────────

BACKUP="${SETTINGS}.bak.$(date +%Y%m%dT%H%M%S)"
cp "$SETTINGS" "$BACKUP"
echo "Backed up settings to: $BACKUP"

# ── Remove this repo's hook entry ────────────────────────────────────────────

# jq remove strategy (idempotent):
#   From .hooks.Notification, drop any entry whose hooks[].command matches
#   our script path.  Leave all other entries and all other top-level keys
#   untouched.
#   If .hooks.Notification becomes an empty array, remove the Notification key.
#   If .hooks becomes empty, remove the hooks key (clean up).

UPDATED="$(jq \
    --arg cmd "$HOOK_SCRIPT" \
    '
    if .hooks.Notification == null then
        # Nothing to remove
        .
    else
        (.hooks.Notification | map(
            select(
                .hooks | map(.command) | any(. == $cmd) | not
            )
        )) as $remaining |

        if ($remaining | length) == 0 then
            # No Notification entries left; remove the key entirely
            if (.hooks | keys | length) == 1 then
                # hooks only had Notification; remove hooks too
                del(.hooks)
            else
                del(.hooks.Notification)
            end
        else
            .hooks.Notification = $remaining
        end
    end
    ' \
    "$SETTINGS")"

TMP_SETTINGS="$(mktemp "${SETTINGS}.tmp.XXXXXX")"
trap 'rm -f "${TMP_SETTINGS:-}"' EXIT
printf '%s\n' "$UPDATED" > "$TMP_SETTINGS"
mv "$TMP_SETTINGS" "$SETTINGS"

echo "Removed hook entry from: $SETTINGS"

# ── Clean up Linux notification state dir (best-effort) ──────────────────────
# Removes per-project id files written by the dedup feature.  Guarded with
# || true so this can NEVER fail the uninstall, even if the dir does not exist
# or is not writable.  Targets only the current user's dir (matches exactly
# the paths the hook creates: XDG primary or /tmp uid-suffixed fallback).
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    rm -rf "${XDG_RUNTIME_DIR}/claude-notifier" 2>/dev/null || true
else
    rm -rf "/tmp/claude-notifier-$(id -u)" 2>/dev/null || true
fi

echo ""
echo "Uninstall complete."
echo "  Restart Claude Code (claude) or run /hooks to apply the change."
echo "  Backup is at: $BACKUP (safe to delete once verified)"
