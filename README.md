# claude-desktop-notifier

Emits a native desktop notification when a running Claude Code session needs attention — waiting for permission approval or idle for ~60 seconds.

Works on **Linux** (GNOME/libnotify via `notify-send`) and **macOS** (Notification Center via `osascript`).

The notification body is the **project name** (derived from the working directory), so you know which terminal to switch to when running multiple sessions in parallel. The title always reads "Claude needs attention".

This is a notify-only tool. There is no click-to-raise, no terminal activation, and no external dependencies beyond the OS notification tool and `jq`.

## What it does

Claude Code fires a `Notification` hook event when it needs input. This tool wires that hook to a shell script that emits a native notification like:

> **Claude needs attention**
> my-project

On Linux the notification uses `critical` urgency by default, so it persists in the GNOME notification tray until dismissed. On macOS, Notification Center banners auto-dismiss (see [macOS notes](#macos) below).

## Dependencies

### Linux

- `notify-send` (package: `libnotify-bin`) — ships with Ubuntu/GNOME by default
- `jq` — JSON processor used to parse the hook payload
- A running GNOME Shell (or any notification daemon reachable via D-Bus)

Install missing dependencies:

```sh
sudo apt install libnotify-bin jq
```

### macOS

- `osascript` — built-in on all macOS versions; no install needed
- `jq` — **not preinstalled on macOS**; install via Homebrew:

```sh
brew install jq
```

## Install as a Claude Code plugin

The easiest way to install is via the Claude Code plugin channel — no `git clone`, no path-baking, no install script needed.

```
/plugin marketplace add chrismou/claude-plugins
/plugin install desktop-notifier@chrismou-claude-plugins
```

### Plugin dependencies

The plugin cannot install OS packages. You must install these yourself before running `/plugin install`:

**Linux:**
```sh
sudo apt install libnotify-bin jq
```

**macOS:**
```sh
brew install jq
```

If `jq` is not installed, the hook still fires and you still get a **"Claude needs attention"** notification, but the body reads **"unknown project"** instead of the actual project name. Claude Code is never blocked.

### Plugin uninstall

```
/plugin uninstall desktop-notifier
```

Note: `uninstall.sh` is for the **standalone install only** — it removes entries from `~/.claude/settings.json` by absolute path and does nothing for the plugin (the plugin wires via a different path).

### Double-notification warning

If you previously ran `./install.sh` **and** then install the plugin (or vice versa), both hooks fire and you receive **two notifications per event**. Pick one channel. To switch from standalone to plugin: run `./uninstall.sh` to remove the `settings.json` entry, then install the plugin. There is no active guard preventing this — the warning here is deliberate, not an oversight.

### Tuning from the plugin channel

The `URGENCY` tunable and the replaceable `assets/claude-icon.svg` live inside the plugin cache (`~/.claude/plugins/cache/...`), which is **overwritten on plugin update** — local edits there are ephemeral. If you want persistent tuning (urgency, icon), use the [standalone install](#installation) instead.

---

## Installation

```sh
git clone https://github.com/youruser/claude-desktop-notifier.git
cd claude-desktop-notifier
./install.sh
```

`install.sh` will:

1. Detect your OS and check the appropriate dependencies.
2. Make `bin/claude-attention-hook.sh` executable.
3. Back up `~/.claude/settings.json`.
4. Merge the `Notification` hook block into `~/.claude/settings.json`, preserving all existing keys.
5. Print next-step instructions.

The install is **idempotent** — running it again does not add duplicate entries.

After installing, reload hooks in any running Claude Code session:

```
/hooks
```

Or restart Claude Code.

**Important (standalone install only):** The repo must remain at its current path after installation. The absolute path to `bin/claude-attention-hook.sh` is baked into `~/.claude/settings.json`. If you move the repo, re-run `./install.sh` from the new location.

## Uninstallation

```sh
./uninstall.sh
```

This removes only this tool's hook entry from `~/.claude/settings.json`. All other settings are left intact. The operation is idempotent and backs up the file first.

## macOS notes {#macos}

- **Persistence:** macOS Notification Center banners auto-dismiss after a few seconds. There is no persistent/never-expire equivalent using built-in `osascript` (that would require `terminal-notifier`, which is out of scope). If you need a persistent notification, check Notification Center after the banner disappears.
- **App attribution:** notifications posted by `osascript` appear as coming from **"Script Editor"** (the host app that owns the AppleScript runtime), not "Claude Code". This is expected and is not a bug. The project name appears in the notification body, which is the load-bearing content. Changing the attributed app name would require a bundled `.app`, which is out of scope.
- **Notification permission:** the first time `osascript` posts a notification, macOS may show a permission prompt for "Script Editor". Grant it to allow notifications. If notifications don't appear, check System Settings → Notifications → Script Editor.
- **Focus/Do Not Disturb:** macOS Focus and Do Not Disturb modes suppress notification banners. If you don't see a banner, check your Focus settings.
- **Urgency:** the `URGENCY` tunable in `bin/claude-attention-hook.sh` applies to Linux only. On macOS it is silently ignored — there is no supported urgency knob for `osascript` notifications.
- **Shell compatibility:** the hook script targets `bash 3.2` (the version shipped with macOS). It uses no bash-4-only features (`declare -A`, `${var^^}`, `mapfile`). The shebang is `#!/usr/bin/env bash`; the script always runs under bash even on systems where the default login shell is zsh.

## Manual installation

If you prefer not to run the install script, copy the relevant block from `settings.snippet.json` into your `~/.claude/settings.json` by hand.

**Important:** `/absolute/path/to/claude-desktop-notifier` in the block below (and in `settings.snippet.json`) is a placeholder — you MUST replace it with the real absolute path to wherever you cloned this repo before saving.

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/claude-desktop-notifier/bin/claude-attention-hook.sh"
          }
        ]
      }
    ]
  }
}
```

**Recommended:** just run `./install.sh` — it merges idempotently and preserves any existing `Notification` hooks. The manual path below is only for those who want to edit by hand.

If you do merge manually, **do not** use a shallow `jq '.[0] * .[1]'` merge: the `*` operator *replaces* the whole `Notification` array, silently discarding any other Notification hooks you already have. Append to the array instead, and write via a private temp file (never a predictable path like `/tmp/merged.json`, which is a symlink-injection risk):

```sh
tmp="$(mktemp)"
jq '.hooks.Notification = ((.hooks.Notification // []) + [{
      "matcher": "",
      "hooks": [{ "type": "command",
                  "command": "/absolute/path/to/claude-desktop-notifier/bin/claude-attention-hook.sh" }]
    }])' ~/.claude/settings.json > "$tmp" \
  && mv "$tmp" ~/.claude/settings.json
```

## Tuning

The notification urgency is a constant at the top of `bin/claude-attention-hook.sh`:

```sh
URGENCY="critical"   # Linux: persists in tray until dismissed
# URGENCY="normal"   # Linux: auto-expires after a few seconds
```

Change `critical` to `normal` if you prefer auto-expiring notifications on Linux. This setting has no effect on macOS.

### Icon (Linux)

The repo includes `assets/claude-icon.svg` — a simple placeholder mark (Anthropic orange sunburst on transparent) displayed alongside the notification on Linux. Replace it with the official Claude logo by overwriting the file:

```sh
cp /path/to/official-claude-logo.svg assets/claude-icon.svg
```

The icon path is resolved relative to the hook script, so it works regardless of the directory name. On macOS, `osascript`'s `display notification` command does not support a custom icon; no icon is used there.

## Testing

Pipe a fake payload directly to the hook script to confirm it works:

```sh
echo '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","cwd":"/home/user/dev/foo"}' \
  | bin/claude-attention-hook.sh
```

You should see a notification titled **"Claude needs attention"** with body **"foo"** (the basename of `cwd`), and the script should exit 0 immediately with no lingering process.

## Troubleshooting

### Linux

**No notification appears when testing manually:**

- Check that `DBUS_SESSION_BUS_ADDRESS` is set in your shell: `echo $DBUS_SESSION_BUS_ADDRESS`
- Test `notify-send` directly: `notify-send "test" "hello"`
- Ensure Do Not Disturb is not enabled in GNOME Settings.

**No notification appears from the real hook (but manual test works):**

- Claude Code's hook subprocess must inherit `DBUS_SESSION_BUS_ADDRESS` and `DISPLAY`. These are normally present when `claude` is launched from an interactive terminal in a GNOME session.
- Confirm the hook is registered: check `~/.claude/settings.json` for the `Notification` key, or run `/hooks` inside Claude Code.

### macOS

**No notification appears when testing manually:**

- Run `osascript -e 'display notification "test" with title "hello"'` directly to confirm `osascript` works.
- Check System Settings → Notifications → Script Editor and ensure notifications are allowed.
- Ensure Do Not Disturb / Focus mode is not active.

**No notification appears from the real hook (but manual test works):**

- Confirm the hook is registered: check `~/.claude/settings.json` for the `Notification` key, or run `/hooks` inside Claude Code.
- The `osascript` subprocess launched by Claude Code's hook runner should have access to your Aqua session automatically; no special environment variable is required.

### Both platforms

**Notification says "unknown project":**

- The hook payload had no `cwd` field. This should not happen in normal use; check Claude Code's hook event format.
- `jq` is not installed. The hook still fires and you get a notification, but the body reads "unknown project" instead of the actual project name. Install `jq` per the [Dependencies](#dependencies) section above; Claude Code is never blocked.

**Duplicate notifications after re-running install.sh:**

- This should not happen — `install.sh` is idempotent and removes any pre-existing entry for this script before adding a fresh one. If you see duplicates, check `~/.claude/settings.json` for multiple entries manually.

**"Notifies even when the terminal is focused" — is that a bug?**

No. Per-tab focus detection is not feasible, and suppressing notifications based on whole-window focus would wrongly swallow the case where you are viewing Tab A while Tab B needs attention. Notifications always fire — this is intentional.

## Architecture

The notifier is a single bash script (`bin/claude-attention-hook.sh`) with no background processes:

```
Claude Code fires Notification hook (JSON on stdin)
      |
      v
bin/claude-attention-hook.sh
      |  jq: parse cwd
      |  derive project label; build title + body (body = "<project>")
      |
      +--[Linux]--> notify-send -u critical -a "Claude Code" [-i <icon>] -- "<title>" "<body>"
      |             (D-Bus -> GNOME Shell shows notification; notify-send exits immediately)
      |
      +--[macOS]--> osascript -e 'display notification "<body>" with title "<title>"'
                    (Notification Center banner; auto-dismisses; exits immediately)
      |
      v
hook exits 0  (no lingering process)
```

Hook config lives in the user-level `~/.claude/settings.json` and applies to all Claude Code projects on this machine.
