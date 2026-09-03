import json
import os
import shutil
import subprocess
import sys
import heapq
from pathlib import Path

import menu


PLAN_QUOTAS = {
  "basic": 2_000_000_000,
  "plus": 2_000_000_000_000,
  "pro": 3_000_000_000_000,
  "professional": 3_000_000_000_000,
  "essentials": 3_000_000_000_000,
}


def read_info():
  info_path = Path.home() / ".dropbox" / "info.json"
  if not info_path.exists():
    return {}
  try:
    with info_path.open("r", encoding="utf-8") as handle:
      return json.load(handle)
  except (OSError, json.JSONDecodeError):
    return {}


def dropbox_account(info):
  for key in ("personal", "business"):
    account = info.get(key)
    if isinstance(account, dict):
      return account
  return {}


def command_output(command):
  try:
    completed = subprocess.run(command, check=False, capture_output=True, text=True, timeout=4)
  except (OSError, subprocess.TimeoutExpired):
    return 1, ""
  return completed.returncode, (completed.stdout + completed.stderr).strip()


def scan_dropbox(path, limit):
  total = 0
  counter = 0
  recent = []
  try:
    for root, dirs, files in os.walk(path):
      dirs[:] = [name for name in dirs if not os.path.islink(os.path.join(root, name))]
      for name in files:
        file_path = os.path.join(root, name)
        if os.path.islink(file_path):
          continue
        try:
          stat = os.stat(file_path)
        except OSError:
          continue
        total += stat.st_size
        rel = os.path.relpath(file_path, path)
        folder = os.path.dirname(rel)
        row = {
          "name": name,
          "path": file_path,
          "folder": "/" if folder in ("", ".") else folder,
          "modifiedTs": int(stat.st_mtime),
          "sizeBytes": stat.st_size,
        }
        counter += 1
        entry = (row["modifiedTs"], counter, row)
        if len(recent) < limit:
          heapq.heappush(recent, entry)
        else:
          heapq.heappushpop(recent, entry)
  except OSError:
    return 0, []
  rows = [entry[2] for entry in sorted(recent, reverse=True)]
  return total, rows


def tray_patched():
  """True when a cloned system tray carries this plugin's tray patch.

  The patch is what makes "Show Dropbox's own tray icon" mean anything, so the
  panel hides that switch on an unpatched system rather than offering a toggle
  that does nothing.
  """
  try:
    for path in (Path.home() / ".config" / "omarchy" / "plugins").glob("*/TrayModel.js"):
      with path.open("r", encoding="utf-8") as handle:
        if "dropbox-extended:patched" in handle.read(4096):
          return True
  except OSError:
    pass
  return False


def menu_state():
  """Sync state from the Dropbox tray menu, or None when it is unreachable."""
  try:
    target = menu.dropbox_menu()
    if target is None:
      return None
    layout = menu.menu_layout(*target)
    if not layout:
      return None
    entries = menu.entries(layout)
    if not entries:
      return None
    state = menu.sync_state(entries)
    return state if state.get("pauseKnown") else None
  except Exception:
    return None


def main():
  limit = 25
  if len(sys.argv) > 1:
    try:
      limit = max(1, min(100, int(sys.argv[1])))
    except ValueError:
      limit = 25

  dropbox_cli = shutil.which("dropbox-cli")
  info = read_info()
  account = dropbox_account(info)
  account_path = account.get("path") if isinstance(account.get("path"), str) else ""
  plan = account.get("subscription_type") if isinstance(account.get("subscription_type"), str) else ""
  quota = PLAN_QUOTAS.get(plan.lower(), 0)
  authenticated = account_path != "" and Path(account_path).exists()

  # Prefer the tray menu over dropbox-cli. The CLI reaches the daemon through a
  # command socket whose accept backlog fills up after long uptime, after which
  # every call reports "Dropbox isn't running!" even while syncing is fine.
  running = False
  status_text = "Not installed"
  state = menu_state()
  if state is not None:
    running = not state["paused"]
    status_text = state["statusText"]
  elif dropbox_cli:
    status_exit, status_output = command_output([dropbox_cli, "status"])
    status_text = status_output if status_exit == 0 and status_output else "Stopped"
    lowered = status_text.lower()
    stopped = "not running" in lowered or "isn't running" in lowered or lowered == "stopped"
    running = status_exit == 0 and status_output != "" and not stopped

  used, files = scan_dropbox(account_path, limit) if authenticated else (0, [])
  usage_percent = (used / quota * 100) if quota > 0 else 0

  print(json.dumps({
    "ok": True,
    "installed": dropbox_cli is not None or state is not None,
    "running": running,
    "authenticated": authenticated,
    "statusText": status_text,
    "accountPath": account_path,
    "plan": plan,
    "usedBytes": used,
    "quotaBytes": quota,
    "usagePercent": usage_percent,
    "quotaKnown": quota > 0,
    "trayPatched": tray_patched(),
    "files": files,
  }))


if __name__ == "__main__":
  main()
