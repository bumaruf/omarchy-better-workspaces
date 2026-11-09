import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// COSMIC-style workspace overview. Every monitor gets a layer surface with a
// vertical strip of workspace thumbnails and a large preview of the selected
// workspace. Click a thumbnail to switch, click a window to focus it, drag a
// window onto a thumbnail to move it there. Keyboard: Up/Down select,
// Return switches, 1-9 jump, Escape closes.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property int selected: 1

  readonly property int stride: 100

  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property color accent: Commons.Color.menu.selectedBackground
  readonly property int cornerRadius: Style.cornerRadius

  function logicalOf(id) {
    return id % root.stride
  }

  readonly property int activeLogical: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id > 0
    ? root.logicalOf(Hyprland.focusedWorkspace.id)
    : 1

  // Same rule as M.count() in init.lua.
  readonly property int count: {
    var highest = 0
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      if (workspace.id > 0 && workspace.toplevels.values.length > 0) highest = Math.max(highest, root.logicalOf(workspace.id))
    }
    return Math.max(highest + 1, root.activeLogical)
  }

  readonly property var logicals: {
    var out = []
    for (var n = 1; n <= root.count; n++) out.push(n)
    return out
  }

  function open(payloadJson) {
    Hyprland.refreshMonitors()
    Hyprland.refreshToplevels()
    root.selected = root.activeLogical
    root.opened = true
    root.revealSelected()
    root.run("o.better_workspaces.overview_opened()")
  }

  function close() {
    if (root.dragToplevel) root.dragCancel()
    root.opened = false
    root.run("o.better_workspaces.overview_closed()")
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "bumaruf.better-workspaces")
  }

  function run(expression) {
    Quickshell.execDetached(["hyprctl", "eval", expression])
  }

  function hexAddress(address) {
    var value = String(address)
    return value.indexOf("0x") === 0 ? value : "0x" + value
  }

  function activate(n) {
    root.run("o.better_workspaces.go(" + n + ")")
    root.dismiss()
  }

  function focusWindow(toplevel) {
    root.run("hl.dispatch(hl.dsp.focus({ window = \"address:" + root.hexAddress(toplevel.address) + "\" }))")
    root.dismiss()
  }

  // Moves the window to logical workspace n on `monitorName` (its own monitor
  // when omitted).
  function moveWindow(toplevel, n, monitorName) {
    var target = monitorName ? ", \"" + monitorName + "\"" : ""
    root.run("o.better_workspaces.move_window(" + n + ", false, \"" + root.hexAddress(toplevel.address) + "\"" + target + ")")
    refreshTimer.restart()
  }

  function insertWindow(toplevel, n, monitorName) {
    root.run("o.better_workspaces.insert_window(" + n + ", \"" + root.hexAddress(toplevel.address) + "\", \"" + monitorName + "\")")
    refreshTimer.restart()
  }

  // Window drag and drop. Each monitor has its own surface, so the drag is
  // tracked in global layout coordinates and every panel can show the ghost
  // and answer which drop target sits under a point.
  property var panels: ({})
  property var dragToplevel: null
  property point dragPoint: Qt.point(0, 0)
  // { screen, kind: "thumb" | "stage" | "gap", n } or null. A gap is the space
  // above thumbnail n; holding a window there for a moment opens it up
  // (armedGap), and dropping into an open gap creates a new workspace n.
  property var dropTarget: null
  property var armedGap: null

  function sameTarget(left, right) {
    return left !== null && right !== null && left.screen === right.screen && left.kind === right.kind && left.n === right.n
  }

  Timer {
    id: gapHold
    interval: 350
    onTriggered: if (root.dropTarget && root.dropTarget.kind === "gap") root.armedGap = root.dropTarget
  }

  function registerPanel(name, panel) {
    var next = ({})
    for (var key in root.panels) next[key] = root.panels[key]
    if (panel) next[name] = panel
    else delete next[name]
    root.panels = next
  }

  function dropTargetAt(point) {
    for (var name in root.panels) {
      var target = root.panels[name].targetAt(point)
      if (target) return target
    }
    return null
  }

  // True once the drag has left the surface it started on.
  property bool handingOff: false

  function dragBegin(toplevel) {
    root.dragToplevel = toplevel
  }

  function dragHandoff() {
    if (!root.dragToplevel || root.handingOff) return
    root.handingOff = true
    root.run("o.better_workspaces.track_drag()")
    handoffTimeout.restart()
  }

  function dragCancel() {
    root.dropTarget = null
    root.dragFinish()
  }

  Timer {
    id: handoffTimeout
    interval: 20000
    onTriggered: root.dragCancel()
  }

  Connections {
    target: Hyprland
    enabled: root.handingOff
    function onRawEvent(event) {
      if (event.name !== "custom") return
      var parts = String(event.data).split(">>")
      if (parts.length !== 2) return
      var xy = parts[1].split(",")
      var point = Qt.point(Number(xy[0]), Number(xy[1]))
      if (parts[0] === "better-workspaces-drag") {
        root.dragMove(point)
      } else if (parts[0] === "better-workspaces-drop") {
        root.dragMove(point)
        root.dragFinish()
      }
    }
  }

  function dragMove(point) {
    root.dragPoint = point
    var target = root.dropTargetAt(point)
    if (!root.sameTarget(target, root.dropTarget)) {
      root.dropTarget = target
      if (target && target.kind === "gap" && !root.sameTarget(target, root.armedGap)) gapHold.restart()
      else gapHold.stop()
      // Leaving the open gap for anything but its own placeholder closes it.
      if (target && target.kind !== "gap") root.armedGap = null
    }
  }

  // A dragged workspace thumbnail (its logical number), or 0.
  property int dragWorkspace: 0

  function workspaceDragBegin(n) {
    root.dragWorkspace = n
  }

  function dragFinish() {
    var target = root.dropTarget
    if (target && root.dragToplevel) {
      if (target.kind !== "gap") root.moveWindow(root.dragToplevel, target.n, target.screen)
      else if (root.sameTarget(target, root.armedGap)) root.insertWindow(root.dragToplevel, target.n, target.screen)
    } else if (target && root.dragWorkspace > 0 && target.kind !== "stage") {
      var from = root.dragWorkspace
      // A gap sits above workspace n; landing there from above means n - 1.
      var to = target.kind === "gap" && from < target.n ? target.n - 1 : target.n
      if (to !== from) {
        root.run("o.better_workspaces.move_workspace_to(" + from + ", " + to + ")")
        root.selected = Math.min(to, root.count)
      }
    }
    gapHold.stop()
    if (root.handingOff) {
      root.handingOff = false
      handoffTimeout.stop()
      root.run("o.better_workspaces.stop_drag()")
    }
    root.dragToplevel = null
    root.dragWorkspace = 0
    root.dropTarget = null
    root.armedGap = null
  }

  function isDropTarget(screen, kind, n) {
    return root.sameTarget(root.dropTarget, { screen: screen, kind: kind, n: n })
  }

  function isArmedGap(screen, n) {
    return root.sameTarget(root.armedGap, { screen: screen, kind: "gap", n: n })
  }

  function step(direction) {
    root.selected = Math.max(1, Math.min(root.count, root.selected + direction))
    root.revealSelected()
  }

  // Asks every panel to scroll its strip so the selected thumbnail is visible.
  signal revealSelected()

  // True while a window or a workspace thumbnail is being dragged.
  readonly property bool dragging: root.dragToplevel !== null || root.dragWorkspace > 0

  // Geometry in lastIpcObject only updates on refresh; keep it fresh while open.
  Timer {
    id: refreshTimer
    interval: 120
    onTriggered: Hyprland.refreshToplevels()
  }

  Connections {
    target: Hyprland
    enabled: root.opened
    function onRawEvent(event) {
      var name = event.name
      if (name === "openwindow" || name === "closewindow" || name === "movewindow" || name === "movewindowv2"
          || name === "changefloatingmode" || name === "fullscreen" || name === "renameworkspace")
        refreshTimer.restart()
    }
  }

  onCountChanged: if (root.selected > root.count) root.selected = root.count

  // A live picture of one monitor's slice of a workspace.
  component WorkspaceView: Item {
    id: view

    property int workspaceId: 0
    property var monitor: null
    // Logical (scaled and rotated) size of the monitor, from its ShellScreen.
    property real monitorWidth: 1920
    property real monitorHeight: 1080
    property bool draggable: true
    // The PanelWindow this view lives in; maps drag points to global coordinates.
    property var host: null
    property bool live: root.opened

    readonly property real monitorX: monitor ? monitor.x : 0
    readonly property real monitorY: monitor ? monitor.y : 0
    readonly property real factor: Math.min(width / monitorWidth, height / monitorHeight)

    readonly property var windows: {
      var out = []
      var values = Hyprland.toplevels.values
      for (var i = 0; i < values.length; i++) {
        var toplevel = values[i]
        if (toplevel.workspace && toplevel.workspace.id === view.workspaceId) out.push(toplevel)
      }
      // Floating windows above tiled ones, most recently focused on top.
      out.sort(function(left, right) {
        var a = left.lastIpcObject || {}
        var b = right.lastIpcObject || {}
        if (!!a.floating !== !!b.floating) return a.floating ? 1 : -1
        return (b.focusHistoryID || 0) - (a.focusHistoryID || 0)
      })
      return out
    }

    Repeater {
      model: view.windows

      Item {
        id: tile
        required property var modelData
        required property int index

        readonly property var ipc: modelData.lastIpcObject || {}
        readonly property var at: ipc.at || [view.monitorX, view.monitorY]
        readonly property var size: ipc.size || [view.monitorWidth, view.monitorHeight]

        x: (at[0] - view.monitorX) * view.factor
        y: (at[1] - view.monitorY) * view.factor
        width: Math.max(1, size[0] * view.factor)
        height: Math.max(1, size[1] * view.factor)
        z: index

        Rectangle {
          anchors.fill: parent
          radius: Math.min(root.cornerRadius, 6)
          color: root.background
          border.color: tileMouse.containsMouse ? root.accent : root.border
          border.width: tileMouse.containsMouse ? 2 : 1
          clip: true

          ScreencopyView {
            id: capture
            anchors.fill: parent
            anchors.margins: parent.border.width
            captureSource: view.live && tile.modelData.wayland ? tile.modelData.wayland : null
            live: view.live
          }

          Text {
            anchors.centerIn: parent
            width: parent.width - 8
            visible: !capture.hasContent
            text: tile.modelData.title || ""
            color: root.foreground
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            font.family: Style.font.family
            font.pixelSize: Math.max(8, Math.min(Style.font.body, parent.height / 4))
          }
        }

        MouseArea {
          id: tileMouse
          anchors.fill: parent
          hoverEnabled: true
          // Thumbnails live inside the scrollable strip; without this the
          // Flickable takes over a vertical drag and cancels it.
          preventStealing: true
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton

          property point pressPoint
          property bool dragging: false

          onPressed: function(mouse) {
            pressPoint = Qt.point(mouse.x, mouse.y)
            dragging = false
          }

          onPositionChanged: function(mouse) {
            if (!view.draggable || !view.host || !pressed) return
            var dx = mouse.x - pressPoint.x
            var dy = mouse.y - pressPoint.y
            if (!dragging && dx * dx + dy * dy > 64) {
              dragging = true
              root.dragBegin(tile.modelData)
            }
            // The pointer stays grabbed by this surface while the button is
            // held, so points past its edge still arrive here.
            if (dragging) root.dragMove(view.host.toGlobal(tileMouse, mouse.x, mouse.y))
          }

          // Hyprland moves the pointer to the next monitor's surface at the
          // edge, which ends the drag here with a cancel or a release outside
          // this surface; Hyprland tracks it from there.
          onCanceled: {
            if (dragging) root.dragHandoff()
            dragging = false
          }

          onReleased: function(mouse) {
            if (dragging) {
              dragging = false
              if (view.host.containsGlobal(root.dragPoint)) root.dragFinish()
              else root.dragHandoff()
            } else if (mouse.button === Qt.MiddleButton) {
              root.run("hl.dispatch(hl.dsp.window.close({ window = \"address:" + root.hexAddress(tile.modelData.address) + "\" }))")
              refreshTimer.restart()
            } else {
              root.focusWindow(tile.modelData)
            }
          }
        }
      }
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel

      required property var modelData
      screen: modelData

      readonly property var monitor: Hyprland.monitorFor(modelData)
      readonly property bool focusedMonitor: monitor !== null && Hyprland.focusedMonitor === monitor
      readonly property int slot: monitor && monitor.activeWorkspace && monitor.activeWorkspace.id > 0
        ? Math.floor(monitor.activeWorkspace.id / root.stride)
        : 0
      readonly property real aspect: modelData.height / modelData.width

      function workspaceId(n) {
        return panel.slot * root.stride + n
      }

      function toGlobal(item, x, y) {
        var point = item.mapToItem(panel.contentItem, x, y)
        return Qt.point(point.x + panel.modelData.x, point.y + panel.modelData.y)
      }

      function containsGlobal(point) {
        var x = point.x - panel.modelData.x
        var y = point.y - panel.modelData.y
        return x >= 0 && y >= 0 && x < panel.width && y < panel.height
      }

      function contains(item, x, y) {
        var point = panel.contentItem.mapToItem(item, x, y)
        return point.x >= 0 && point.y >= 0 && point.x < item.width && point.y < item.height
      }

      // The drop target under a global point, if it is on this monitor.
      function targetAt(point) {
        var x = point.x - panel.modelData.x
        var y = point.y - panel.modelData.y
        if (x < 0 || y < 0 || x >= panel.width || y >= panel.height) return null

        if (panel.contains(previewFrame, x, y))
          return { screen: panel.modelData.name, kind: "stage", n: root.selected }

        var local = panel.contentItem.mapToItem(column, x, y)
        if (local.x < 0 || local.x >= column.width) return null
        // Thumbnails scrolled out of view are clipped away; they are not targets.
        // (Above the first one is still fine while the strip is at the top.)
        if (local.y < strip.contentY && strip.contentY > 0) return null
        if (local.y >= strip.contentY + strip.height && local.y < column.height) return null
        for (var i = 0; i < column.children.length; i++) {
          var child = column.children[i]
          if (child.modelData === undefined) continue
          var top = local.y - child.y
          // Above the first thumbnail there is no neighbour, so give its gap
          // some room of its own to land in.
          var gapTop = child.modelData > 1 ? -column.spacing : -panel.thumbHeight * 0.3
          if (top >= gapTop && top < child.gapHeight + panel.thumbHeight * 0.2)
            return { screen: panel.modelData.name, kind: "gap", n: child.modelData }
          if (top >= gapTop && top < child.height)
            return { screen: panel.modelData.name, kind: "thumb", n: child.modelData }
        }

        return null
      }

      Component.onCompleted: root.registerPanel(panel.modelData.name, panel)
      Component.onDestruction: root.registerPanel(panel.modelData.name, null)

      visible: root.opened
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore

      WlrLayershell.namespace: "better-workspaces-overview"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: panel.focusedMonitor ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.94)

        MouseArea {
          anchors.fill: parent
          onClicked: root.dismiss()
        }

        // While dragging, the wheel or a two-finger swipe anywhere on the
        // overview scrolls the strip, not only over the strip itself.
        WheelHandler {
          target: null
          enabled: root.dragging
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          onWheel: function(event) {
            var delta = event.pixelDelta.y !== 0
              ? event.pixelDelta.y
              : event.angleDelta.y / 120 * panel.thumbHeight * 0.5
            panel.scrollStrip(-delta)
          }
        }
      }

      Item {
        id: keys
        anchors.fill: parent
        focus: true

        Component.onCompleted: if (panel.focusedMonitor) forceActiveFocus()
        Connections {
          target: root
          function onOpenedChanged() {
            if (root.opened && panel.focusedMonitor) keys.forceActiveFocus()
          }
        }

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape && root.dragToplevel) {
            root.dragCancel()
          } else if (event.key === Qt.Key_Escape) {
            root.dismiss()
          } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Left || event.key === Qt.Key_K) {
            root.step(-1)
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Right || event.key === Qt.Key_J) {
            root.step(1)
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.activate(root.selected)
          } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            root.activate(Math.min(root.count, event.key - Qt.Key_0))
          } else {
            return
          }
          event.accepted = true
        }
      }

      readonly property real margin: Math.round(panel.height * 0.05)
      readonly property real stripWidth: Math.round(panel.width * 0.14)
      readonly property real thumbHeight: Math.round(stripWidth * aspect)

      // Scrolls the strip by `delta` pixels, clamped to its content.
      function scrollStrip(delta) {
        var max = Math.max(0, strip.contentHeight - strip.height)
        strip.contentY = Math.max(0, Math.min(max, strip.contentY + delta))
      }

      // Brings thumbnail n fully into view.
      function revealThumb(n) {
        for (var i = 0; i < column.children.length; i++) {
          var child = column.children[i]
          if (child.modelData !== n) continue
          var top = child.y + child.gapHeight
          var bottom = top + panel.thumbHeight
          if (top < strip.contentY) panel.scrollStrip(top - strip.contentY)
          else if (bottom > strip.contentY + strip.height) panel.scrollStrip(bottom - strip.contentY - strip.height)
          return
        }
      }

      Connections {
        target: root
        function onRevealSelected() { Qt.callLater(panel.revealThumb, root.selected) }
      }

      // Edge auto-scroll while dragging. Holding the pointer (mouse or
      // touchpad) near the top or bottom of the strip, or past it in the
      // margin, scrolls towards workspaces that do not fit on screen; the
      // closer to the edge, the faster.
      readonly property real edgeZone: Math.max(40, panel.thumbHeight * 0.4)
      readonly property real edgeSpeed: Math.max(8, panel.thumbHeight / 10)

      function edgeVelocity(point) {
        var x = point.x - panel.modelData.x
        var y = point.y - panel.modelData.y
        if (x < 0 || y < 0 || x >= panel.width || y >= panel.height) return 0
        if (x > strip.x + strip.width + panel.margin) return 0
        var intoTop = strip.y + panel.edgeZone - y
        var intoBottom = y - (strip.y + strip.height - panel.edgeZone)
        var depth = intoTop > 0 ? intoTop : intoBottom > 0 ? intoBottom : 0
        if (depth <= 0) return 0
        var speed = panel.edgeSpeed * Math.max(0.15, Math.min(1, depth / panel.edgeZone))
        return intoTop > 0 ? -speed : speed
      }

      Timer {
        interval: 16
        repeat: true
        running: root.opened && root.dragging && strip.contentHeight > strip.height
        onTriggered: {
          var velocity = panel.edgeVelocity(root.dragPoint)
          if (velocity !== 0) panel.scrollStrip(velocity)
        }
      }

      // Workspace strip.
      Flickable {
        id: strip
        x: panel.margin
        width: panel.stripWidth
        height: Math.min(contentHeight, panel.height - panel.margin * 2)
        anchors.verticalCenter: parent.verticalCenter
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        // Thumbnails slide under a stationary pointer while scrolling, so the
        // drop target has to be looked up again.
        onContentYChanged: if (root.dragging) root.dragMove(root.dragPoint)

        Column {
          id: column
          width: strip.width
          spacing: Style.space(12)

          Repeater {
            model: root.logicals

            Item {
              id: thumb
              required property int modelData

              readonly property bool isActive: modelData === root.activeLogical
              readonly property bool isSelected: modelData === root.selected
              readonly property bool isEmpty: thumbView.windows.length === 0
              readonly property bool isDropTarget: root.isDropTarget(panel.modelData.name, "thumb", modelData)
              readonly property bool gapHovered: root.isDropTarget(panel.modelData.name, "gap", modelData)
              readonly property bool gapOpen: root.isArmedGap(panel.modelData.name, modelData)
              property real gapHeight: gapOpen ? panel.thumbHeight * 0.6 + column.spacing : 0
              Behavior on gapHeight { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

              width: column.width
              height: gapHeight + panel.thumbHeight

              // New workspace placeholder.
              Rectangle {
                width: parent.width
                height: Math.max(0, thumb.gapHeight - column.spacing)
                visible: height > 1
                radius: root.cornerRadius
                color: "transparent"
                border.color: root.accent
                border.width: 2
                opacity: Math.min(1, height / (panel.thumbHeight * 0.3))

                Text {
                  anchors.centerIn: parent
                  text: "+"
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Math.min(parent.height * 0.5, Style.font.title * 2)
                }
              }

              // Hint while hovering a gap that has not opened yet.
              Rectangle {
                width: parent.width
                height: 3
                radius: 1.5
                // The strip clips, so the first thumbnail's hint sits inside it.
                y: thumb.modelData > 1 ? -column.spacing / 2 - 1.5 : 0
                visible: thumb.gapHovered && !thumb.gapOpen
                color: root.accent
              }

              Item {
                id: card
                y: thumb.gapHeight
                width: parent.width
                height: panel.thumbHeight

                Rectangle {
                  anchors.fill: parent
                  radius: root.cornerRadius
                  color: root.background
                  border.width: thumb.isSelected || thumb.isDropTarget ? 3 : 1
                  border.color: thumb.isSelected || thumb.isDropTarget ? root.accent : root.border
                  opacity: thumb.isEmpty && !thumb.isActive ? 0.6 : 1
                }

                // Click switches; dragging the thumbnail reorders workspaces.
                MouseArea {
                  id: cardMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  preventStealing: true

                  property point pressPoint
                  property bool dragging: false

                  onEntered: if (!root.dragWorkspace) root.selected = thumb.modelData
                  onPressed: function(mouse) {
                    pressPoint = Qt.point(mouse.x, mouse.y)
                    dragging = false
                  }
                  onPositionChanged: function(mouse) {
                    if (!pressed) return
                    var dx = mouse.x - pressPoint.x
                    var dy = mouse.y - pressPoint.y
                    if (!dragging && dx * dx + dy * dy > 64 && !thumb.isEmpty) {
                      dragging = true
                      root.workspaceDragBegin(thumb.modelData)
                    }
                    if (dragging) root.dragMove(panel.toGlobal(cardMouse, mouse.x, mouse.y))
                  }
                  onReleased: {
                    if (dragging) {
                      dragging = false
                      root.dragFinish()
                    } else {
                      root.activate(thumb.modelData)
                    }
                  }
                  onCanceled: {
                    if (dragging) root.dragCancel()
                    dragging = false
                  }
                }

                WorkspaceView {
                  id: thumbView
                  anchors.fill: parent
                  anchors.margins: 6
                  workspaceId: panel.workspaceId(thumb.modelData)
                  monitor: panel.monitor
                  monitorWidth: panel.modelData.width
                  monitorHeight: panel.modelData.height
                  host: panel
                }

                Text {
                  anchors.left: parent.left
                  anchors.bottom: parent.bottom
                  anchors.margins: 8
                  text: thumb.isEmpty && thumb.modelData === root.count ? thumb.modelData + "  +" : String(thumb.modelData)
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: thumb.isActive
                  style: Text.Outline
                  styleColor: root.background
                }
              }
            }
          }
        }
      }

      // Large preview of the selected workspace.
      Item {
        id: stage
        anchors.left: strip.right
        anchors.leftMargin: panel.margin
        anchors.right: parent.right
        anchors.rightMargin: panel.margin
        anchors.top: parent.top
        anchors.topMargin: panel.margin
        anchors.bottom: parent.bottom
        anchors.bottomMargin: panel.margin

        readonly property real previewWidth: Math.min(width, height / panel.aspect)

        Rectangle {
          id: previewFrame
          anchors.centerIn: parent
          width: stage.previewWidth
          height: stage.previewWidth * panel.aspect
          radius: root.cornerRadius
          color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.6)
          readonly property bool isDropTarget: root.isDropTarget(panel.modelData.name, "stage", root.selected)

          border.color: isDropTarget ? root.accent : root.border
          border.width: isDropTarget ? 3 : 1

          MouseArea {
            anchors.fill: parent
            onClicked: root.activate(root.selected)
          }

          WorkspaceView {
            id: stageView
            anchors.fill: parent
            anchors.margins: 8
            workspaceId: panel.workspaceId(root.selected)
            monitor: panel.monitor
            monitorWidth: panel.modelData.width
            monitorHeight: panel.modelData.height
            host: panel
          }

          Text {
            anchors.centerIn: parent
            visible: stageView.windows.length === 0
            text: "Workspace " + root.selected + " is empty"
            color: root.foreground
            opacity: 0.6
            font.family: Style.font.family
            font.pixelSize: Style.font.title
          }
        }
      }

      // Fallback drop for a handed-off drag: click where the window should go.
      MouseArea {
        anchors.fill: parent
        z: 99
        enabled: root.handingOff
        onPressed: function(mouse) {
          root.dragMove(panel.toGlobal(this, mouse.x, mouse.y))
          root.dragFinish()
        }
      }

      // The window being dragged, drawn on whichever monitor the pointer is over.
      Rectangle {
        id: ghost

        readonly property real localX: root.dragPoint.x - panel.modelData.x
        readonly property real localY: root.dragPoint.y - panel.modelData.y

        visible: (root.dragToplevel !== null || root.dragWorkspace > 0) && localX >= 0 && localY >= 0 && localX < panel.width && localY < panel.height
        z: 100
        x: localX - width / 2
        y: localY - height / 2
        width: panel.stripWidth * 0.8
        height: width * panel.aspect
        radius: Math.min(root.cornerRadius, 6)
        color: root.background
        border.color: root.accent
        border.width: 2
        opacity: 0.9
        clip: true

        ScreencopyView {
          anchors.fill: parent
          anchors.margins: 2
          captureSource: ghost.visible && root.dragToplevel && root.dragToplevel.wayland ? root.dragToplevel.wayland : null
          live: ghost.visible
        }

        Text {
          anchors.centerIn: parent
          visible: root.dragWorkspace > 0
          text: String(root.dragWorkspace)
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.title * 2
          font.bold: true
        }
      }
    }
  }
}
