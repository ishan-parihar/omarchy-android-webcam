import QtQuick
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// One setting, as a tile the width of the panel.
//
// The kit's `Toggle` parks its switch beside the text and centers it
// vertically. In a panel this narrow that reads badly twice over: the
// description is squeezed into a ribbon next to the switch, and two tiles
// whose descriptions differ in length end up with their switches at
// different heights -- which is what the torch and microphone tiles looked
// like, the two cards the same control in a different place.
//
// Here the switch rides the title row and the description runs the full
// width under it, so both tiles are the same shape: a label with its
// switch, and a paragraph. Same fill, border and radius as the kit's Toggle,
// built from the same pieces it is built from.
BorderSurface {
  id: root

  property string label: ""
  property string description: ""
  property bool checked: false

  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family

  signal clicked()

  readonly property bool _hot: mouse.containsMouse

  color: Style.controlFill(false, _hot, root.foreground, root.accent)
  borderSpec: Border.controlSpec(_hot ? "hover-cursor" : "normal", root.foreground, root.accent)
  radius: Style.cornerRadius

  Behavior on color { ColorAnimation { duration: Style.duration(100) } }

  // The tile's own height, so the panel can measure it: the content plus
  // the same breathing room the kit's Toggle gives its row.
  implicitHeight: Math.max(Style.space(54), content.implicitHeight + Style.spacing.huge)

  // The tile owns the click, so the switch is presentation only.
  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: root.borderLeft + Style.spacing.rowPaddingX
    anchors.rightMargin: root.borderRight + Style.spacing.rowPaddingX
    spacing: Style.spacing.xs

    // The title row, and the switch in it: whatever the description below
    // does, both tiles' switches stand at the same height.
    Item {
      width: parent.width
      implicitHeight: Math.max(titleText.implicitHeight, track.implicitHeight)

      Text {
        id: titleText
        textFormat: Text.PlainText
        text: root.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        // Room for the switch, so a long label is cut rather than run
        // under the control it belongs to.
        width: parent.width - track.implicitWidth - Style.spacing.rowPaddingX
      }

      ToggleSwitch {
        id: track
        checked: root.checked
        rounded: Style.cornerRadius > 0
        foreground: root.foreground
        accent: root.accent
        // No cursor of its own to highlight, so the ring only appears
        // under the pointer: a ring that is always drawn is a switch
        // wearing a permanent hover state.
        interactive: false
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: root.description !== ""
      text: root.description
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      width: parent.width
    }
  }
}