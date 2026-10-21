import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Dynamic workspace indicators: one button per logical workspace (see
// hypr/better-workspaces/init.lua), plus the trailing empty one. Workspace
// id = slot * stride + n, so n is the same on every monitor.
BarWidget {
  id: root
  moduleName: "bumaruf.better-workspaces"

  readonly property int stride: 100

  function logicalOf(id) {
    return id % root.stride
  }

  function windowCount(n) {
    var count = 0
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      if (workspace.id > 0 && root.logicalOf(workspace.id) === n) count += workspace.toplevels.values.length
    }
    return count
  }

  readonly property int activeLogical: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id > 0
    ? root.logicalOf(Hyprland.focusedWorkspace.id)
    : 1

  // Mirrors M.count() in init.lua: every occupied workspace, the active one,
  // and one empty workspace after the last occupied.
  function logicals() {
    var highest = 0
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      if (workspace.id > 0 && workspace.toplevels.values.length > 0) highest = Math.max(highest, root.logicalOf(workspace.id))
    }

    var count = Math.max(highest + 1, root.activeLogical)
    var out = []
    for (var n = 1; n <= count; n++) out.push(n)
    return out
  }

  function run(expression) {
    Quickshell.execDetached(["hyprctl", "eval", expression])
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  WheelHandler {
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: function(event) {
      root.run("o.better_workspaces.step(" + (event.angleDelta.y < 0 ? 1 : -1) + ")")
    }
  }

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : repeater.count
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      id: repeater
      model: root.logicals()

      WidgetButton {
        required property int modelData

        readonly property bool occupied: root.windowCount(modelData) > 0
        readonly property bool focused: root.activeLogical === modelData

        bar: root.bar
        text: focused ? "󱓻" : String(modelData)
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.run("o.better_workspaces.go(" + modelData + ")") }
      }
    }
  }
}
