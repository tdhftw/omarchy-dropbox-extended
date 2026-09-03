#!/usr/bin/env python3
"""Patch a cloned Omarchy system-tray widget to cooperate with dropbox-extended.

Two behaviours are grafted onto the stock tray:

  * Dropbox's native status-notifier item is suppressed while the
    dropbox-extended bar widget is in the layout, the way stock Omarchy
    suppresses it for its own `omarchy.dropbox` widget. Setting
    `showTrayIcon: true` on the widget's shell.json entry hands it back.

  * When the item *is* shown, it is recolored to the bar foreground instead of
    being drawn as Dropbox's own blue-and-white PNG, so it matches the rest of
    the bar under every Omarchy theme.

The patch is applied by anchored surgery on whatever tray version is installed,
not as a frozen fork, so re-running it after an `omarchy update` re-applies the
same two changes to the new upstream code. Every anchor is required: a miss
aborts without touching the file rather than half-patching the tray.
"""

import re
import sys
from pathlib import Path

MARKER = "dropbox-extended:patched"

TRAY_MODEL_HELPERS = '''// --- dropbox-extended ------------------------------------------------------
// A Dropbox bar widget owns Dropbox's presence in the bar, so the native tray
// item is hidden while one is in the layout — the same deal stock Omarchy makes
// for `omarchy.dropbox`. `showTrayIcon: true` on that widget's own shell.json
// entry opts back in, and `themedItem` then tells Tray.qml to recolor the item
// rather than render Dropbox's shipped PNG.
var DROPBOX_WIDGET_IDS = ["omarchy.dropbox", "dropbox-extended"]

function dropboxWidgetEntry(layout) {
  var sections = ["left", "center", "right"]
  for (var s = 0; s < sections.length; s++) {
    var entries = layout && layout[sections[s]]
    if (!Array.isArray(entries)) continue
    for (var i = 0; i < entries.length; i++) {
      var id = entryId(entries[i])
      // Match the stock id, this plugin's id, and any personal clone of either
      // (`omarchy plugin clone` renames to "<user>.dropbox").
      if (DROPBOX_WIDGET_IDS.indexOf(id) === -1 && id.slice(-8) !== ".dropbox") continue
      return entries[i] && typeof entries[i] === "object" ? entries[i] : { id: id }
    }
  }
  return null
}

function dropboxTrayIconShown(layout) {
  var entry = dropboxWidgetEntry(layout)
  return !!entry && entry.showTrayIcon === true
}

// A tray item the shell should recolor to the bar foreground rather than draw
// as shipped.
function themedItem(item, layout) {
  return itemNamed(item, "dropbox") && dropboxTrayIconShown(layout)
}

'''

TRAY_MODEL_FUNCTION = '''function ownedByOmarchy(item, layout) {
  if (itemNamed(item, "localsend")) return true
  if (!itemNamed(item, "dropbox")) return false
  return !!dropboxWidgetEntry(layout) && !dropboxTrayIconShown(layout)
}
'''

THEMED_EFFECT = """    // dropbox-extended: a themed icon is drawn as a silhouette — the bar
    // foreground poured through the icon's own alpha — rather than tinted.
    // Colorization preserves luminance, which is right for a symbolic icon
    // (already near-white) but leaves an app's full-color logo muddy.
    Rectangle {
      id: themedFill
      anchors.fill: trayIconImage
      color: root.foreground
      // Never drawn directly; it exists to be sampled as the effect's texture,
      // the same way trayIconImage is for a symbolic icon.
      visible: false
      layer.enabled: trayIconRoot.themed
    }

    MultiEffect {
      anchors.fill: trayIconImage
      source: trayIconRoot.themed ? themedFill : trayIconImage
      visible: trayIconRoot.symbolic
      maskEnabled: trayIconRoot.themed
      maskSource: trayIconImage
      // Colorization is luminance-preserving, so running it over the solid
      // fill would darken the silhouette by the foreground's own luminance.
      colorization: trayIconRoot.themed ? 0.0 : 1.0
      colorizationColor: root.foreground
    }"""

TRAY_QML_FUNCTION = '''  // dropbox-extended: tray items this shell recolors even though their icon is
  // not a freedesktop "-symbolic" one. Read through shell.shellConfig, not
  // bar.layoutConfig: an inline settings change is patched into layoutConfig in
  // place, which fires no change signal, so a binding on it would never notice
  // the toggle. shellConfig is reassigned wholesale on every write.
  function iconIsThemed(item) {
    if (!item) return false
    var config = root.bar && root.bar.shell ? root.bar.shell.shellConfig : null
    var layout = config && config.bar ? config.bar.layout : null
    if (!layout) layout = root.bar && root.bar.layoutConfig ? root.bar.layoutConfig : null
    return TrayModel.themedItem(item, layout)
  }

'''


def fail(message):
  print("dropbox-extended tray patch: " + message, file=sys.stderr)
  sys.exit(1)


def patch_tray_model(text):
  # Replace the whole ownedByOmarchy definition rather than a line inside it, so
  # the patch survives upstream reformatting of the function body. The comment
  # block above it is carried along and re-emitted against the new function, so
  # upstream's explanation does not end up stranded over this plugin's helpers.
  pattern = re.compile(
    r"((?:^//[^\n]*\n)*)^function ownedByOmarchy\(item, layout\) \{.*?^\}\n", re.S | re.M)
  match = pattern.search(text)
  if not match:
    fail("TrayModel.js: could not find `function ownedByOmarchy(item, layout)`")
  text = pattern.sub(
    lambda m: TRAY_MODEL_HELPERS + m.group(1) + TRAY_MODEL_FUNCTION, text, count=1)

  exports = "    ownedByOmarchy: ownedByOmarchy"
  if exports not in text:
    fail("TrayModel.js: could not find the ownedByOmarchy entry in module.exports")
  text = text.replace(
    exports,
    exports + ",\n"
    "    dropboxWidgetEntry: dropboxWidgetEntry,\n"
    "    dropboxTrayIconShown: dropboxTrayIconShown,\n"
    "    themedItem: themedItem",
    1,
  )
  return text


def patch_tray_qml(text):
  anchor = "  function trayTooltip(item) {"
  if anchor not in text:
    fail("Tray.qml: could not find `function trayTooltip(item)`")
  text = text.replace(anchor, TRAY_QML_FUNCTION + anchor, 1)

  classify = "  function classifyItem(item) {\n"
  if classify not in text:
    fail("Tray.qml: could not find `function classifyItem(item)`")
  text = text.replace(
    classify,
    classify +
    "    // dropbox-extended: Dropbox's tray id carries its pid, so it changes\n"
    "    // with every daemon restart and a hand-pinned entry never survives one.\n"
    "    // Pin from the setting instead — \"show the icon\" has to mean visible in\n"
    "    // the bar, not filed away in the collapsed drawer.\n"
    "    if (iconIsThemed(item)) return \"pinned\"\n",
    1,
  )

  symbolic = "    readonly property bool symbolic: root.iconIsSymbolic(icon)"
  if symbolic not in text:
    fail("Tray.qml: could not find TrayIcon's `symbolic` binding")
  text = text.replace(
    symbolic,
    "    // dropbox-extended: the tray item behind this icon, so a themed item\n"
    "    // can be recolored the way a symbolic one is.\n"
    "    property var item: null\n"
    "    readonly property bool themed: root.iconIsThemed(item)\n"
    "    readonly property bool symbolic: root.iconIsSymbolic(icon) || themed",
    1,
  )

  effect = """    MultiEffect {
      anchors.fill: trayIconImage
      source: trayIconImage
      visible: trayIconRoot.symbolic
      colorization: 1.0
      colorizationColor: root.foreground
    }"""
  if effect not in text:
    fail("Tray.qml: could not find TrayIcon's recoloring MultiEffect")
  text = text.replace(effect, THEMED_EFFECT, 1)

  # Feed each TrayIcon the item its icon came from. Both call sites already have
  # `modelData` in scope; indentation is copied from the icon line.
  count = 0
  for holder in ("rowRoot", "trayItemRoot"):
    call = re.compile(r"^([ \t]*)icon: %s\.modelData\.icon$" % holder, re.M)
    match = call.search(text)
    if not match:
      fail("Tray.qml: could not find `icon: %s.modelData.icon`" % holder)
    text = call.sub(lambda m: "%sicon: %s.modelData.icon\n%sitem: %s.modelData"
                    % (m.group(1), holder, m.group(1), holder), text, count=1)
    count += 1
  if count != 2:
    fail("Tray.qml: expected two TrayIcon call sites")
  return text


def apply(plugin_dir):
  model = plugin_dir / "TrayModel.js"
  qml = plugin_dir / "Tray.qml"
  for path in (model, qml):
    if not path.is_file():
      fail("missing %s — is %s a clone of omarchy.tray?" % (path.name, plugin_dir))

  model_text = model.read_text(encoding="utf-8")
  qml_text = qml.read_text(encoding="utf-8")
  if MARKER in model_text or MARKER in qml_text:
    print("already patched — nothing to do")
    return

  header = "// %s — https://github.com/tdhftw/omarchy-dropbox-extended\n" % MARKER
  model_out = header + patch_tray_model(model_text)
  qml_out = header + patch_tray_qml(qml_text)

  # Both files are rewritten only after both patched cleanly.
  for path in (model, qml):
    backup = path.with_suffix(path.suffix + ".prepatch")
    if not backup.exists():
      backup.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
  model.write_text(model_out, encoding="utf-8")
  qml.write_text(qml_out, encoding="utf-8")
  print("patched %s and %s" % (model.name, qml.name))


def revert(plugin_dir):
  restored = 0
  for name in ("TrayModel.js", "Tray.qml"):
    path = plugin_dir / name
    backup = path.with_suffix(path.suffix + ".prepatch")
    if backup.exists():
      path.write_text(backup.read_text(encoding="utf-8"), encoding="utf-8")
      backup.unlink()
      restored += 1
  print("restored %d file(s)" % restored if restored else "nothing to revert — was it patched?")


def main():
  if len(sys.argv) < 3 or sys.argv[1] not in ("apply", "revert"):
    fail("usage: patch.py apply|revert <tray-plugin-dir>")
  plugin_dir = Path(sys.argv[2]).expanduser()
  if not plugin_dir.is_dir():
    fail("not a directory: %s" % plugin_dir)
  (apply if sys.argv[1] == "apply" else revert)(plugin_dir)


if __name__ == "__main__":
  main()
