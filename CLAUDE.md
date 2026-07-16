# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A notify-only desktop notifier for Claude Code: wires the `Notification` hook event to a single bash script (`bin/claude-attention-hook.sh`) that emits a native notification naming the project that needs attention. Supports **Linux** (`notify-send`/libnotify) and **macOS** (`osascript`/Notification Center). **Windows is explicitly out of scope** — do not add Windows/PowerShell/WSL branches.

The repo/dir name says "gnome" for historical reasons; the tool is Linux + macOS. Do not rename files/dirs to fix this.

The full design doc lives at `plans/20260715-gnome-attention-notifier.md` (gitignored, local only) — consult it before changing scope or behavior; its decisions are marked FIXED.

## Commands

There is no build, lint, or test framework. Everything is plain bash + `jq`.

Test the hook script end-to-end by piping a fake payload:

```sh
echo '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","cwd":"/home/user/dev/foo"}' \
  | bin/claude-attention-hook.sh
```

Expected: a notification titled "foo needs attention" with body "Claude needs your permission to use Bash", exit 0, no lingering process.

Install/uninstall (idempotent, back up and merge/prune `~/.claude/settings.json` via jq):

```sh
./install.sh
./uninstall.sh
```

Lint shell changes with `shellcheck` if available.

## Architecture

Three scripts, no background processes:

- `bin/claude-attention-hook.sh` — the hook. Reads JSON from stdin, parses `cwd` with jq, derives a project label, and branches **only at the final emit step**: `notify-send` on Linux, `osascript` (argv-passing heredoc, injection-proof) on macOS. Everything before the emit is shared, OS-agnostic code — do not fork into per-OS scripts.
- `install.sh` — preflight dep checks per OS, then idempotently merges a `Notification` hook entry (absolute path to the script, baked in at install time) into `~/.claude/settings.json`. Removes any prior entry pointing at the same command before appending, preserves all other keys/hooks, writes via mktemp + atomic mv.
- `uninstall.sh` — inverse: prunes only entries matching this repo's script path; removes `Notification`/`hooks` keys if left empty.

`settings.snippet.json` is the manual-install reference block shown in the README.

## Hard constraints (from the design doc — do not relax)

- **Never block Claude Code.** The hook must always exit 0 — bad/empty payloads warn to stderr and exit 0; emitter failures are swallowed with `|| true`.
- **bash 3.2 compatible** (macOS stock bash): no `declare -A`, `${var^^}`, `mapfile`. Use `#!/usr/bin/env bash`.
- **Portability:** no `basename -- "$x"` (BSD basename mishandles `--`); use parameter expansion instead.
- **Notification-only scope:** wire the `Notification` hook only (not `Stop`). No click-to-raise, no terminal/window activation, no focus-based suppression — always notify. These are deliberate decisions, not missing features.
- **No new dependencies** beyond `jq` and the OS notification tool (no `terminal-notifier`, no Python, no D-Bus glue).
- Notification format: title is "`<project>` needs attention" (project = basename of `cwd`, leading so title truncation never hides it); body is the payload's `message` text. Fallbacks: no derivable project (jq absent, or `cwd` missing/empty) → static title "Claude needs attention"; no derivable message → empty body. `URGENCY` tunable is Linux-only and silently ignored on macOS.
- Settings merges must be surgical: never use a shallow `jq '.[0] * .[1]'` merge (it clobbers other `Notification` hooks); always append/prune within the array and write via a private temp file.

## Plugin install channel

This repo also ships as a Claude Code plugin (`desktop-notifier`) via the `chrismou/claude-plugins` marketplace. The plugin install channel and the standalone `./install.sh` channel both wire **the same single hook script** — `bin/claude-attention-hook.sh`. Never fork them.

### File layout

- `.claude-plugin/plugin.json` — plugin manifest. Name is `desktop-notifier` (FIXED; differs from the repo name deliberately — do not "fix" it).
- `hooks/hooks.json` — declares the `Notification` hook for plugin installs. Uses `${CLAUDE_PLUGIN_ROOT}` (substituted by Claude Code at runtime to the plugin's cache path).

### Version-bump rule (IMPORTANT)

**Every behavior-affecting commit must bump `version` in `.claude-plugin/plugin.json`.** Claude Code's plugin update flow keys off this field — forgetting to bump means plugin users never receive updates. Cosmetic/doc-only changes do not require a bump.

### Quoting in `hooks/hooks.json` is load-bearing

The `command` string in `hooks/hooks.json` wraps `${CLAUDE_PLUGIN_ROOT}/...` in literal double-quotes (JSON-escaped as `\"`):

```
"command": "\"${CLAUDE_PLUGIN_ROOT}/bin/claude-attention-hook.sh\""
```

This is required because the cache path under `$HOME` can contain spaces (common on macOS, e.g. `/Users/First Last/...`). An unquoted variable would word-split. Do not "clean up" these quotes.

### Install channel comparison

| | Standalone (`./install.sh`) | Plugin (`/plugin install`) |
|---|---|---|
| Hook wiring | `~/.claude/settings.json` (absolute path baked in at install time) | `hooks/hooks.json` via `${CLAUDE_PLUGIN_ROOT}` |
| Preflight (dep check) | Yes — exits 1 if jq / notify-send missing | No — hook degrades gracefully if jq absent |
| Idempotency key | Absolute repo path of the script | Plugin name (`desktop-notifier`) |
| Tuning (URGENCY, icon) | Edit repo files; persists across updates | Edit plugin cache files; **lost on plugin update** |

A user who has both channels active receives two notifications per event. This is documented in the README (not guarded in code — deliberate per design doc decision §0a.3).
