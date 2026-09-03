#!/bin/bash
#
# Teach the Omarchy system tray about the dropbox-extended widget.
#
#   ./tray/install.sh            clone omarchy.tray (if needed) and patch it
#   ./tray/install.sh --refresh  re-copy the packaged tray, then re-patch it
#   ./tray/install.sh --revert   put the clone back the way it was
#
# The packaged tray under /usr/share/omarchy is never touched. Omarchy's own
# `omarchy plugin clone` makes the editable copy; this script only patches it,
# so after an `omarchy update` you re-run with --refresh to rebase the two
# changes onto the new upstream tray instead of carrying a stale fork.

set -euo pipefail

PLUGINS_DIR="$HOME/.config/omarchy/plugins"
UPSTREAM_TRAY="${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins/bar/widgets"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODE="apply"

fail() {
  echo "dropbox-extended: $*" >&2
  exit 1
}

case "${1:-}" in
"") ;;
--refresh) MODE="refresh" ;;
--revert) MODE="revert" ;;
-h | --help)
  sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
  ;;
*) fail "unknown option: $1" ;;
esac

command -v jq >/dev/null || fail "jq is required"
command -v omarchy >/dev/null || fail "this is not an Omarchy system"

# A tray clone is any user plugin whose manifest records omarchy.tray as its
# source. Matching on clonedFrom rather than on a directory name keeps working
# whatever the clone ended up being called.
find_tray_clone() {
  local manifest
  for manifest in "$PLUGINS_DIR"/*/manifest.json; do
    [[ -f $manifest ]] || continue
    if [[ $(jq -r '.omarchy.clonedFrom // ""' "$manifest") == "omarchy.tray" ]]; then
      dirname "$manifest"
      return 0
    fi
  done
  return 1
}

tray_dir="$(find_tray_clone || true)"

if [[ -z $tray_dir ]]; then
  [[ $MODE == "apply" ]] || fail "no clone of omarchy.tray found — run without --$MODE first"
  echo "Cloning omarchy.tray..."
  omarchy plugin clone omarchy.tray
  tray_dir="$(find_tray_clone)" || fail "clone succeeded but the plugin was not found"
fi

echo "Tray plugin: $tray_dir"

if [[ $MODE == "refresh" ]]; then
  [[ -f $UPSTREAM_TRAY/Tray.qml ]] || fail "packaged tray not found at $UPSTREAM_TRAY"
  echo "Re-copying the packaged tray over the clone..."
  rm -f "$tray_dir"/Tray.qml.prepatch "$tray_dir"/TrayModel.js.prepatch
  cp -L "$UPSTREAM_TRAY/Tray.qml" "$tray_dir/Tray.qml"
  cp -L "$UPSTREAM_TRAY/TrayModel.js" "$tray_dir/TrayModel.js"
  MODE="apply"
fi

if [[ $MODE == "revert" ]]; then
  python3 -B "$HERE/patch.py" revert "$tray_dir"
else
  python3 -B "$HERE/patch.py" apply "$tray_dir"
fi

# Widget code hot-reloads on save, but the tray rebuilds its item list from a
# function the reload does not re-run, so give it a clean start.
omarchy restart shell
echo "Done."
