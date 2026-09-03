"""Drive the Dropbox tray menu over D-Bus.

The Dropbox client exports its whole tray menu (Preferences, Open Dropbox
Folder, Launch Dropbox Website, ...) as a com.canonical.dbusmenu object, but
Omarchy's tray hides the item whenever a Dropbox bar widget is in the layout,
so nothing in the bar can reach it. This talks to that menu directly.

Item ids are regenerated every time the client rebuilds its menu, so entries
are always looked up by label rather than cached.

  python3 menu.py list            -> JSON array of top-level entries
  python3 menu.py status          -> JSON sync state read from the menu
  python3 menu.py click "<label>" -> activate the entry whose label matches
"""

import json
import re
import subprocess
import sys


def command_output(command):
  try:
    completed = subprocess.run(command, check=False, capture_output=True, text=True, timeout=4)
  except (OSError, subprocess.TimeoutExpired):
    return 1, ""
  return completed.returncode, completed.stdout.strip()


def dropbox_menu():
  """Return (bus_name, menu_object_path) for the Dropbox tray item, or None."""
  exit_code, output = command_output([
    "busctl", "--user", "get-property", "org.kde.StatusNotifierWatcher",
    "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
    "RegisteredStatusNotifierItems",
  ])
  if exit_code != 0:
    return None
  for entry in re.findall(r'"([^"]+)"', output):
    if "dropbox" not in entry.lower() or "/" not in entry:
      continue
    bus, path = entry.split("/", 1)
    return bus, "/" + path + "/Menu"
  return None


def menu_layout(bus, path):
  # AboutToShow lets the client populate the menu before it is read; some
  # entries are only filled in lazily.
  command_output(["gdbus", "call", "--session", "-d", bus, "-o", path,
                  "-m", "com.canonical.dbusmenu.AboutToShow", "0"])
  # Depth 1: immediate children only. Recursing pulls in the Recently Changed
  # Files and Snooze submenus, whose entries would otherwise be indistinguishable
  # from top-level ones and could be matched by accident.
  exit_code, output = command_output([
    "gdbus", "call", "--session", "-d", bus, "-o", path,
    "-m", "com.canonical.dbusmenu.GetLayout", "0", "--", "1", "[]",
  ])
  return output if exit_code == 0 else ""


def entries(layout):
  """Top-level entries as (id, label, enabled, is_submenu) tuples.

  Property order inside each entry's dict is not guaranteed, so each dict is
  matched whole and then picked apart by key. Separators carry no label and
  drop out; disabled rows are kept because Dropbox reports live sync state
  through them ("Up to date", the account email, the quota line).
  """
  found = []
  for item_id, props in re.findall(r"\((\d+), (\{[^{}]*\}), @av \[\]\)", layout):
    label = re.search(r"'label': <'((?:[^']|'')*)'>", props)
    if label is None:
      continue
    text = label.group(1).replace("''", "'").strip()
    if not text:
      continue
    found.append((
      int(item_id),
      text,
      "'enabled': <false>" not in props,
      "'children-display': <'submenu'>" in props,
    ))
  return found


def resolve():
  target = dropbox_menu()
  if target is None:
    sys.exit("Dropbox is not exporting a tray menu (is the client running?)")
  layout = menu_layout(*target)
  if not layout:
    sys.exit("Could not read the Dropbox tray menu")
  return target, entries(layout)


QUOTA_LINE = re.compile(r"^[\d.]+% of ")


def sync_state(found):
  """Sync state as Dropbox itself reports it in the tray menu.

  The client keeps a disabled row holding the live status ("Up to date",
  "Syncing 3 files..."), alongside a disabled account email and quota line.
  Whether syncing is paused shows up as the toggle entry flipping between
  Pause Syncing and Resume Syncing.
  """
  status_text = ""
  paused = None
  for _, label, enabled, submenu in found:
    lowered = label.lower()
    if not enabled:
      if "@" in label or QUOTA_LINE.match(label):
        continue
      status_text = label
    elif not submenu:
      if lowered.startswith("pause syncing"):
        paused = False
      elif lowered.startswith("resume syncing"):
        paused = True

  return {
    "running": True,
    "paused": bool(paused),
    "pauseKnown": paused is not None,
    "statusText": status_text or ("Syncing paused" if paused else "Running"),
  }


def main():
  action = sys.argv[1] if len(sys.argv) > 1 else "list"

  if action == "list":
    _, found = resolve()
    print(json.dumps([
      {"label": label, "enabled": enabled, "submenu": submenu}
      for _, label, enabled, submenu in found
    ]))
    return

  if action == "status":
    _, found = resolve()
    print(json.dumps(sync_state(found)))
    return

  if action == "click":
    if len(sys.argv) < 3:
      sys.exit("click needs a label")
    wanted = sys.argv[2].strip().lower()
    (bus, path), found = resolve()
    for item_id, label, enabled, submenu in found:
      if not enabled or submenu:
        continue
      normalized = label.strip().lower().rstrip(".…")
      if normalized == wanted or normalized.startswith(wanted):
        command_output(["gdbus", "call", "--session", "-d", bus, "-o", path,
                        "-m", "com.canonical.dbusmenu.Event",
                        str(item_id), "clicked", "<0>", "0"])
        print(label)
        return
    sys.exit("No Dropbox menu entry matching %r" % sys.argv[2])

  sys.exit("Usage: menu.py list | status | click <label>")


if __name__ == "__main__":
  main()
