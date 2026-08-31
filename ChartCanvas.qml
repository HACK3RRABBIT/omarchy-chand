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

  // Hover marker: set hoverX (pixel, in this item's coords) to draw a vertical
  // crosshair + dot at the nearest point; set to -1 to hide.
  property real hoverX: -1

  readonly property int n: Array.isArray(root.points) ? root.points.length : 0

  // Map a pixel x (canvas local) to the nearest data point {ts, toman}.
  function pointAtX(px) {
    if (root.n < 2) return null
    var innerW = Math.max(1, root.width - root.padX * 2)
    var i = Math.round(((px - root.padX) / innerW) * (root.n - 1))
    if (i < 0) i = 0
    if (i > root.n - 1) i = root.n - 1
    return root.points[i]
  }
  function xAtPoint(p) {
    if (root.n < 2) return root.padX
    var innerW = Math.max(1, root.width - root.padX * 2)
    var i = root.points.indexOf(p)
    if (i < 0) i = 0
    return root.padX + (innerW * i) / (root.n - 1)
  }

  onPointsChanged: requestPaint()
  onColorChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()
  onHoverXChanged: requestPaint()

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

    // Hover crosshair + marker.
    if (root.hoverX >= 0) {
      var hp = root.pointAtX(root.hoverX)
      if (hp) {
        var hx = root.xAtPoint(hp)
        var hy = yAt(Number(hp.toman))
        ctx.save()
        ctx.strokeStyle = Qt.darker(root.color, 1.0)
        ctx.globalAlpha = 0.5
        ctx.setLineDash([3, 3])
        ctx.beginPath()
        ctx.moveTo(hx, py)
        ctx.lineTo(hx, h - py)
        ctx.stroke()
        ctx.setLineDash([])
        ctx.globalAlpha = 1
        ctx.fillStyle = root.color
        ctx.beginPath()
        ctx.arc(hx, hy, 3.5, 0, Math.PI * 2)
        ctx.fill()
        ctx.restore()
      }
    }
  }
}
