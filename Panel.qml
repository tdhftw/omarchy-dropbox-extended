import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "dropbox-extended"
  ipcTarget: "dropbox-extended"
  manageIpc: false

  // Items inside the panel's lazily built content, null until it first
  // opens. Code inside the content reaches its own ids directly.
  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null
  readonly property Item hero: panel.loadedContent ? panel.loadedContent.hero : null
  readonly property Item fileColumn: panel.loadedContent ? panel.loadedContent.fileColumn : null
  readonly property Item actionColumn: panel.loadedContent ? panel.loadedContent.actionColumn : null
  readonly property Item trayIconRow: panel.loadedContent ? panel.loadedContent.trayIconRow : null

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property string focusSection: "login"
  property int fileIndex: 0
  property int actionIndex: 0
  property bool cursorActive: false
  property int phraseIndex: 0

  readonly property var activePhrases: [
    Commons.I18n.t("dropbox.phrase1"),
    Commons.I18n.t("dropbox.phrase2"),
    Commons.I18n.t("dropbox.phrase3"),
    Commons.I18n.t("dropbox.phrase4"),
    Commons.I18n.t("dropbox.phrase5"),
    Commons.I18n.t("dropbox.phrase6"),
    Commons.I18n.t("dropbox.phrase7"),
    Commons.I18n.t("dropbox.phrase8"),
    Commons.I18n.t("dropbox.phrase9"),
    Commons.I18n.t("dropbox.phrase10")
  ]
  readonly property string heroPhraseText: activePhrases[phraseIndex % activePhrases.length]

  // Entries worth surfacing from Dropbox's own tray menu, filtered down to the
  // ones the running client actually offers. Labels are matched loosely by
  // menu.py, so "Preferences" finds "Preferences...".
  readonly property var menuActions: {
    var wanted = [
      { label: "Preferences", glyph: "\uf013", hint: "Selective Sync, bandwidth, account" },
      { label: "Open Dropbox Folder", glyph: "\uf07b", hint: "Browse the local folder" },
      { label: "Launch Dropbox Website", glyph: "\uf0ac", hint: "Open dropbox.com" }
    ]
    var out = []
    for (var i = 0; i < wanted.length; i++) {
      if (dropbox.hasMenuEntry(wanted[i].label)) out.push(wanted[i])
    }
    return out
  }
  readonly property bool hasActions: menuActions.length > 0

  // Dropbox ships its own status-notifier icon. A Dropbox bar widget makes that
  // icon redundant, so the tray hides it — see tray/install.sh, which teaches
  // the tray to read this setting. Without that patch nothing reads it, so the
  // row is left out rather than offered as a switch that does nothing.
  readonly property bool showTrayIcon: setting("showTrayIcon", false) === true
  readonly property bool canToggleTrayIcon: dropbox.trayPatched

  // Cursor stops in visual order. Sections come and go with the data behind
  // them, so navigation walks this list rather than hard-coding neighbours.
  readonly property var cursorSections: {
    var out = ["header"]
    if (hasActions) out.push("actions")
    if (canToggleTrayIcon) out.push("trayIcon")
    if (dropbox.files.length > 0) out.push("files")
    return out
  }
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color iconColor: dropbox.authenticated && dropbox.active ? foreground : dim
  readonly property string toggleHint: dropbox.active ? Commons.I18n.t("dropbox.pauseSyncing") : Commons.I18n.t("dropbox.resumeSyncing")
  readonly property color barIconColor: dropbox.authenticated && dropbox.active ? barForeground : Qt.darker(barForeground, 1.55)
  // Only claim the header cursor when the switch is actually on screen —
  // "header" stays navigable, but an absent CLI leaves nothing to highlight.
  readonly property bool headerHasCursor: cursorActive && focusSection === "header" && dropbox.installed

  function ensureCursor() {
    if (!dropbox.authenticated) {
      focusSection = "login"
      actionIndex = 0
      fileIndex = 0
      return
    }
    // A section can vanish under the cursor when a refresh drops the last
    // recent file or Dropbox stops offering a menu entry.
    if (cursorSections.indexOf(focusSection) === -1) focusSection = "header"
    actionIndex = Math.max(0, Math.min(actionIndex, menuActions.length - 1))
    fileIndex = Math.max(0, Math.min(fileIndex, dropbox.files.length - 1))
  }

  function sectionLength(name) {
    if (name === "actions") return menuActions.length
    if (name === "files") return dropbox.files.length
    return 1
  }

  function sectionIndex(name) {
    if (name === "actions") return actionIndex
    if (name === "files") return fileIndex
    return 0
  }

  function setSectionIndex(name, value) {
    if (name === "actions") actionIndex = value
    else if (name === "files") fileIndex = value
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    var step = dy > 0 ? 1 : -1
    var at = cursorSections.indexOf(focusSection)
    if (at === -1) {
      setHeaderCursor()
      return
    }
    // Walk within the current section first, then step to the next one and
    // enter it from the edge the cursor arrived at.
    var next = sectionIndex(focusSection) + step
    if (next >= 0 && next < sectionLength(focusSection)) {
      setSectionIndex(focusSection, next)
      scrollCursorIntoView()
      return
    }
    var target = at + step
    if (target < 0 || target >= cursorSections.length) return
    var name = cursorSections[target]
    focusSection = name
    setSectionIndex(name, step > 0 ? 0 : sectionLength(name) - 1)
    if (name === "header") setHeaderCursor()
    else scrollCursorIntoView()
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    if (panelFlick) panelFlick.contentY = 0
  }

  function toggleRunning() {
    if (dropbox.installed && !dropbox.busy) dropbox.toggleRunning()
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "login") dropbox.login()
    else if (focusSection === "header") toggleRunning()
    else if (focusSection === "actions") openSelectedAction()
    else if (focusSection === "trayIcon") toggleTrayIcon()
    else if (focusSection === "files") dropbox.openFile(selectedFile())
  }

  function openSelectedAction() {
    if (!hasActions) return
    var action = menuActions[Math.max(0, Math.min(actionIndex, menuActions.length - 1))]
    if (action) dropbox.openMenuItem(action.label)
  }

  // Writes back this widget's own inline shell.json entry. updateEntryInline
  // replaces the entry outright, so every existing setting has to be carried
  // over — dropping one here would silently reset it.
  function setShowTrayIcon(value) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return
    var entry = {}
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.showTrayIcon = value === true
    bar.shell.updateEntryInline(moduleName, entry)
  }

  function toggleTrayIcon() {
    if (canToggleTrayIcon) setShowTrayIcon(!showTrayIcon)
  }

  function setTrayIconCursor() {
    cursorActive = true
    focusSection = "trayIcon"
    scrollCursorIntoView()
  }

  function setActionCursor(index) {
    cursorActive = true
    focusSection = "actions"
    actionIndex = index
    scrollCursorIntoView()
  }

  function selectedFile() {
    if (dropbox.files.length === 0) return null
    return dropbox.files[Math.max(0, Math.min(fileIndex, dropbox.files.length - 1))]
  }

  function setFileCursor(index) {
    cursorActive = true
    focusSection = "files"
    fileIndex = index
    scrollCursorIntoView()
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (focusSection === "files" && fileColumn && fileIndex >= 0 && fileIndex < fileColumn.children.length) {
      scrollItemIntoView(fileColumn.children[fileIndex])
    } else if (focusSection === "actions" && actionColumn && actionIndex >= 0 && actionIndex < actionColumn.children.length) {
      scrollItemIntoView(actionColumn.children[actionIndex])
    } else if (focusSection === "trayIcon" && trayIconRow) {
      scrollItemIntoView(trayIconRow)
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    if (panelFlick) panelFlick.contentY = 0
    dropbox.refresh()
    dropbox.refreshMenu()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }
  onFileIndexChanged: scrollCursorIntoView()
  onActionIndexChanged: scrollCursorIntoView()

  Service {
    id: dropbox
    settings: root.settings
    omarchyPath: root.omarchyPath
  }

  Connections {
    target: dropbox
    function onAuthenticatedChanged() { root.ensureCursor() }
    function onFilesChanged() { root.ensureCursor() }
    function onMenuEntriesChanged() { root.ensureCursor() }
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { dropbox.refresh(); return "ok" }
    function login(): string { dropbox.login(); return "ok" }
    function preferences(): string { dropbox.openMenuItem("Preferences"); return "ok" }
    function trayIcon(state: string): string {
      if (!root.canToggleTrayIcon) return "the system tray is not patched; run tray/install.sh"
      var value = String(state || "").toLowerCase()
      if (value === "on" || value === "show" || value === "true") root.setShowTrayIcon(true)
      else if (value === "off" || value === "hide" || value === "false") root.setShowTrayIcon(false)
      else root.toggleTrayIcon()
      return root.showTrayIcon ? "on" : "off"
    }
    function status(): string { return dropbox.statusText }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        DropboxIcon {
          x: (parent.width - width) / 2
          y: (parent.height - height) / 2
          iconSize: button.iconSize / aspectRatio
          artworkScale: 1
          color: root.barIconColor
          opacity: dropbox.active ? 1.0 : 0.6
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) dropbox.refresh()
      else if (buttonCode === Qt.MiddleButton) dropbox.login()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(560))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      property alias hero: hero
      property alias fileColumn: fileColumn
      property alias actionColumn: actionColumn
      property alias trayIconRow: trayIconRow
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") dropbox.refresh()
        else if (t === "l" || t === "L") dropbox.login()
        else if (t === "p" || t === "P") root.toggleRunning()
        else if (t === ",") dropbox.openMenuItem("Preferences")
        else if (t === "o" || t === "O") dropbox.openMenuItem("Open Dropbox Folder")
        else if (t === "w" || t === "W") dropbox.openMenuItem("Launch Dropbox Website")
        else if (t === "t" || t === "T") root.toggleTrayIcon()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            visible: dropbox.authenticated
            width: parent.width
            implicitHeight: hero.implicitHeight
            // Exposed for the hero's trailingControl, whose `root` resolves to
            // PanelHero (not this Panel) — reach panel state via `header`.
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.setHeaderCursor() }

            PanelHero {
              id: hero
              width: parent.width
              title: Commons.I18n.t("dropbox.title")
              meta: dropbox.active ? root.heroPhraseText : Commons.I18n.t("dropbox.syncingPaused")
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: dropbox.active ? 1.0 : 0.5
              // Status only — the switch owns toggling, mouse and keyboard alike.
              iconComponent: Component {
                DropboxIcon {
                  iconSize: Style.font.display
                  color: root.iconColor
                }
              }

              // Compact on/off switch on the trailing edge of the hero, and the
              // header's only cursor target. The service already flips `active`
              // optimistically, so the knob throws the instant you click it.
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: dropbox.installed
                  checked: dropbox.active
                  busy: dropbox.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: root.toggleRunning()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.toggleHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: dropbox.actionStatus !== "" || dropbox.lastError !== ""
            width: parent.width
            text: dropbox.actionStatus !== "" ? dropbox.actionStatus : dropbox.lastError
            color: dropbox.lastError !== "" && dropbox.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          LoginButton {
            visible: !dropbox.authenticated
            width: parent.width
          }

          Column {
            visible: dropbox.authenticated
            width: parent.width
            spacing: Style.spacing.labelGap

            Column {
              width: parent.width
              spacing: Style.spacing.labelGap
              InfoPair { label: Commons.I18n.t("dropbox.stored"); value: Model.usageText(dropbox.usedBytes, dropbox.quotaBytes, dropbox.quotaKnown, Commons.I18n.t, Commons.I18n.formatNumber) }
            }
          }

          PanelSeparator {
            visible: dropbox.authenticated
            foreground: root.foreground
          }

          Column {
            visible: dropbox.authenticated && (root.hasActions || root.canToggleTrayIcon)
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "DROPBOX APP"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              id: actionColumn
              visible: root.hasActions
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.menuActions
                ActionRow {
                  required property var modelData
                  required property int index
                  width: actionColumn.width
                  action: modelData
                  rowIndex: index
                }
              }
            }

            // Dropbox's own status-notifier icon. Off by default, because this
            // widget is what stands in for it. The row exists only on a tray
            // carrying tray/install.sh's patch — nothing else reads the setting.
            Toggle {
              id: trayIconRow
              visible: root.canToggleTrayIcon
              width: parent.width
              // Tab belongs to the panel's own cycling, not to this control.
              activeFocusOnTab: false
              label: "Dropbox tray icon"
              description: root.showTrayIcon
                ? "Shown in the system tray, recolored to match the bar."
                : "Hidden — this widget stands in for it."
              checked: root.showTrayIcon
              hasCursor: root.cursorActive && root.focusSection === "trayIcon"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleTrayIcon()
              onHovered: function(isHovered) { if (isHovered) root.setTrayIconCursor() }
            }
          }

          PanelSeparator {
            visible: dropbox.authenticated && (root.hasActions || root.canToggleTrayIcon)
            foreground: root.foreground
          }

          Column {
            visible: dropbox.authenticated
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: Commons.I18n.t("dropbox.recentFiles")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: dropbox.files.length === 0
              width: parent.width
              text: Commons.I18n.t("dropbox.noFiles")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: fileColumn
              visible: dropbox.files.length > 0
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: dropbox.files
                FileRow {
                  required property var modelData
                  required property int index
                  width: fileColumn.width
                  file: modelData
                  rowIndex: index
                }
              }
            }
          }
        }
      }
    }
  }

  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && dropbox.authenticated && dropbox.active
    repeat: true
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: hero; property: "metaOpacity"
      to: 0.0; duration: Style.duration(150); easing.type: Easing.OutCubic
    }
    ScriptAction {
      script: root.phraseIndex = (root.phraseIndex + 1) % root.activePhrases.length
    }
    PropertyAnimation {
      target: hero; property: "metaOpacity"
      to: 1.0; duration: Style.duration(200); easing.type: Easing.OutCubic
    }
  }

  component LoginButton: CursorSurface {
    id: loginButton

    hasCursor: root.cursorActive && root.focusSection === "login"
    foreground: root.foreground

    implicitHeight: loginRow.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: dropbox.installed && !dropbox.busy ? Qt.PointingHandCursor : Qt.ArrowCursor
      enabled: dropbox.installed && !dropbox.busy
      onEntered: {
        root.cursorActive = true
        root.focusSection = "login"
      }
      onClicked: dropbox.login()
    }

    RowLayout {
      id: loginRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: dropbox.installed ? Commons.I18n.t("dropbox.login") : Commons.I18n.t("dropbox.notInstalled")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: dropbox.installed ? Commons.I18n.t("dropbox.loginHelp") : Commons.I18n.t("dropbox.installHelp")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: "󰌋"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: dropbox.installed && !dropbox.busy
        Layout.alignment: Qt.AlignVCenter
        onClicked: dropbox.login()
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property var action: null
    property int rowIndex: 0
    readonly property string label: action ? String(action.label || "") : ""
    readonly property string hint: action ? String(action.hint || "") : ""

    hasCursor: root.cursorActive && root.focusSection === "actions" && root.actionIndex === rowIndex
    foreground: root.foreground

    implicitHeight: actionContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setActionCursor(actionRow.rowIndex)
      onClicked: dropbox.openMenuItem(actionRow.label)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: actionRow.action ? String(actionRow.action.glyph || "") : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: actionContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: actionRow.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: actionRow.hint !== ""
          Layout.fillWidth: true
          text: actionRow.hint
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component FileRow: CursorSurface {
    id: fileRow
    property var file: null
    property int rowIndex: 0
    readonly property string fileName: file ? String(file.name || Commons.I18n.t("dropbox.untitled")) : Commons.I18n.t("dropbox.untitled")

    hasCursor: root.cursorActive && root.focusSection === "files" && root.fileIndex === rowIndex
    foreground: root.foreground

    implicitHeight: fileContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setFileCursor(fileRow.rowIndex)
      onClicked: dropbox.openFile(fileRow.file)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: Model.fileGlyph(fileRow.fileName)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: fileContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: fileRow.fileName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: Model.fileMeta(fileRow.file, undefined, Commons.I18n.t, Commons.I18n.formatNumber)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }
}
