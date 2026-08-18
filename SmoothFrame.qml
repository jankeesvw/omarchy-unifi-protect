import QtQuick

// A picture that swaps to a new file without blinking.
//
// Every refresh writes a new file, so the path changes each time. Pointing one
// Image at it means the old picture is dropped the instant the source changes
// and the new one is not decoded yet, which reads as a flash once a second.
//
// So there are two: `incoming` loads the new path with nothing on screen, and
// only once it reports Ready does `shown` take that path over. `shown` finds
// it in Qt's pixmap cache and swaps in the same frame, with no empty moment in
// between. Caching is on for exactly that reason, and it is safe here because
// the paths are unique per frame rather than one path being overwritten.
Item {
  id: root

  property string source: ""
  property int fillMode: Image.PreserveAspectCrop

  readonly property bool ready: shown.status === Image.Ready

  Image {
    id: shown
    anchors.fill: parent
    fillMode: root.fillMode
    // The snapshots are 2688 px wide and this is a few hundred. Decoding at
    // display size keeps a full-resolution frame per camera out of memory.
    sourceSize.width: Math.round(root.width)
    asynchronous: true
    cache: true
  }

  Image {
    id: incoming
    source: root.source
    visible: false
    asynchronous: true
    cache: true
    sourceSize.width: Math.round(root.width)
    onStatusChanged: if (status === Image.Ready) shown.source = source
  }
}
