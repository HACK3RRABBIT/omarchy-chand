import QtQuick
import QtQuick.Controls

// Area/spark chart for the Detail screen. Paints strictly within its own
// bounds (the parent clips), so nothing is drawn outside the card.
//
// Props:
//   points : array of { ts, toman }  (already range-filtered by the caller)
//   color  : line/area stroke color
//   fill   : area fill color (with alpha)
//
// Requires >= 2 points to draw a line; the panel decides whether to show this
// or a "Collecting history" placeholder when points < 2.

Canvas {
  id: root

  property var points: []
  property color color: "#22c55e"
  property color fill: "#22c55e"
  property real lineWidth: 2
  property real padX: 6
  property real padY: 6

  readonly property int n: Array.isArray(root.points) ? root.points.length : 0

  onPointsChanged: requestPaint()
  onColorChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  antialiasing: true
  clip: true

  onPaint: {
    var ctx = getContext("2d")
    ctx.clearRect(0, 0, width, height)
    if (root.n < 2) return

    var vals = []
    var min = Infinity, max = -Infinity
    for (var i = 0; i < root.n; i++) {
      var v = Number(root.points[i].toman)
      if (!isFinite(v)) continue
      vals.push(v)
      if (v < min) min = v
      if (v > max) max = v
    }
    if (vals.length < 2) return
    if (max === min) { max += 1; min -= 1 }

    var w = width, h = height
    var px = root.padX, py = root.padY
    var innerW = Math.max(1, w - px * 2)
    var innerH = Math.max(1, h - py * 2)

    function xAt(i) { return px + (innerW * i) / (vals.length - 1) }
    function yAt(v) { return py + innerH * (1 - (v - min) / (max - min)) }

    // Area fill.
    ctx.beginPath()
    ctx.moveTo(xAt(0), yAt(vals[0]))
    for (var j = 1; j < vals.length; j++) ctx.lineTo(xAt(j), yAt(vals[j]))
    ctx.lineTo(xAt(vals.length - 1), h - py)
    ctx.lineTo(xAt(0), h - py)
    ctx.closePath()
    ctx.fillStyle = root.fill
    ctx.fill()

    // Line.
    ctx.beginPath()
    ctx.moveTo(xAt(0), yAt(vals[0]))
    for (var k = 1; k < vals.length; k++) ctx.lineTo(xAt(k), yAt(vals[k]))
    ctx.strokeStyle = root.color
    ctx.lineWidth = root.lineWidth
    ctx.lineJoin = "round"
    ctx.stroke()
  }
}
