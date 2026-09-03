# Dropbox Extended

An Omarchy bar widget for Dropbox. It is a fork of Omarchy's built-in
`omarchy.dropbox` widget with the two things that widget is missing: a way to
reach Dropbox's *own* windows (Preferences, and therefore Selective Sync), and
a status readout that doesn't fall over when `dropbox-cli` stops answering.

![The Omarchy bar: the tray chevron, Dropbox's own tray icon recolored to the theme, then the Dropbox Extended widget](docs/bar.png)

## Why

Omarchy's stock widget is deliberately status-only, and while it is in your bar
the tray hides Dropbox's own status-notifier icon. That combination leaves the
Dropbox client's Preferences window — the only place Selective Sync lives on
Linux — unreachable from the bar. There is no CLI for it either: `dropbox-cli`
has no `preferences` command.

The stock widget also reads status through `dropbox-cli`, which talks to the
daemon over `~/.dropbox/command_socket`. After long daemon uptime that socket's
accept backlog fills, `connect()` starts failing with `EAGAIN`, and every call
reports `Dropbox isn't running!` while syncing is in fact fine — which makes
the pause/resume toggle useless exactly when you'd want it.

## What it adds

- **DROPBOX APP section** — Preferences, Open Dropbox Folder, and Launch
  Dropbox Website, driven straight from the Dropbox client's own tray menu over
  D-Bus (`com.canonical.dbusmenu`). Only the entries your client actually offers
  are listed.
- **Status and pause/resume from the tray menu**, with `dropbox-cli` kept as a
  fallback. This keeps working through the wedged-socket failure above.
- **Optional native tray icon.** Off by default, because this widget stands in
  for it. Turn it on and it comes back — recolored to the bar foreground so it
  follows your Omarchy theme instead of showing Dropbox's blue-and-white PNG.
  Needs the tray patch below.
- Keyboard shortcuts for all of it, and IPC methods you can bind to keys.

Everything else — storage summary, recent files, login flow, the hero switch —
is the stock widget's, and stays.

## Requirements

- Omarchy 4.x
- The official Dropbox client, running
- `python3` (already on any Omarchy system)
- `dropbox-cli` is optional; it is only used as a fallback

## Install

```bash
omarchy plugin add https://github.com/tdhftw/omarchy-dropbox-extended
omarchy plugin enable dropbox-extended --section right
```

> Plugins run as unsandboxed code inside `omarchy-shell`. Read the source before
> you enable it — it is about 2,000 lines, most of them the stock widget's.

The manifest records `omarchy.dropbox` as its source, so a layout entry that
still says `omarchy.dropbox` renders this widget instead once it is enabled.

## The tray patch (optional)

The "show Dropbox's own tray icon" setting is read by the *tray* widget, not by
this one, so it needs a two-change patch to the tray:

```bash
cd ~/.config/omarchy/plugins/dropbox-extended
./tray/install.sh
```

That clones `omarchy.tray` with Omarchy's own `omarchy plugin clone` (your bar
switches to the clone, exactly as if you had cloned it by hand) and patches the
clone. `/usr/share/omarchy` is never touched.

The patch is applied by anchored surgery on whatever tray version is installed,
not shipped as a frozen fork, so after an `omarchy update`:

```bash
./tray/install.sh --refresh   # re-copy the new upstream tray, re-apply the patch
./tray/install.sh --revert    # or put the clone back the way it was
```

Any anchor it cannot find aborts the whole run rather than half-patching the
tray. Without the patch everything else still works; the panel simply leaves
the tray-icon row out.

What the patch changes:

1. `TrayModel.js` — Dropbox's tray item is hidden while a Dropbox widget is in
   the bar (this is what stock Omarchy already does for `omarchy.dropbox`),
   unless `showTrayIcon` is set on that widget's layout entry.
2. `Tray.qml` — a shown Dropbox item is drawn as a silhouette: the bar
   foreground poured through the icon's own alpha. It is also pinned rather
   than filed into the collapsed drawer, because Dropbox's tray id carries the
   daemon's pid and a hand-pinned entry never survives a restart.

Dropbox only ships its status icons at 16×16, so the tray icon is a little soft
on a HiDPI screen. Nothing this plugin can fix.

## Settings

`~/.config/omarchy/shell.json`, on the widget's own layout entry:

```json
{ "id": "dropbox-extended", "refreshIntervalSec": 60, "showTrayIcon": false }
```

| Key | Type | Default | What it does |
|---|---|---|---|
| `refreshIntervalSec` | integer, 10–3600 | `60` | How often status, storage, and recent files are re-read |
| `showTrayIcon` | boolean | `false` | Keep Dropbox's own tray icon in the tray, themed. Needs the tray patch |

## Keyboard

With the panel open:

| Key | Action |
|---|---|
| `↑` `↓` / `Enter` | Move the cursor / activate |
| `r` | Refresh |
| `l` | Log in |
| `p` | Pause / resume syncing |
| `,` | Preferences (Selective Sync lives here) |
| `o` | Open the Dropbox folder |
| `w` | Open dropbox.com |
| `t` | Toggle Dropbox's own tray icon |
| `Tab` | Next bar panel |
| `Esc` | Close |

On the bar icon itself: left click opens the panel, right click refreshes,
middle click starts the login flow.

## IPC

```bash
omarchy-shell dropbox-extended preferences    # open Dropbox's Preferences window
omarchy-shell dropbox-extended status         # print the current status line
omarchy-shell dropbox-extended refresh
omarchy-shell dropbox-extended login
omarchy-shell dropbox-extended toggle         # toggle the panel
omarchy-shell dropbox-extended trayIcon on    # on | off | (empty to flip)
```

Handy as a Hyprland binding, since Dropbox has no CLI for its Preferences
window:

```lua
o.bind("SUPER SHIFT", "D", "omarchy-shell dropbox-extended preferences")
```

## How it talks to Dropbox

`menu.py` finds Dropbox's registered `StatusNotifierItem`, then reads and
clicks its menu over `com.canonical.dbusmenu` with `gdbus`. Menu item ids are
regenerated every time Dropbox rebuilds the menu, so entries are looked up by
label, matched loosely (`Preferences` finds `Preferences…`). Only enabled,
non-submenu entries are clickable, so a click can never land on a filename in
the *Recently Changed Files* submenu.

```bash
python3 menu.py list      # what the running client offers
python3 menu.py status    # parsed sync state
python3 menu.py click "Preferences"
```

## Updating

```bash
omarchy plugin update dropbox-extended
```

After an `omarchy update`, re-run `./tray/install.sh --refresh` if you use the
tray patch.

## Uninstall

```bash
cd ~/.config/omarchy/plugins/dropbox-extended && ./tray/install.sh --revert
omarchy plugin remove dropbox-extended
```

## License

MIT. Derived from Omarchy's `omarchy.dropbox` plugin, also MIT.
