// Draws the app icon: a play symbol sending out radio waves, on a gradient from
// YT Music's red to Apple Music's pink: radio from one, played in the other.
// Usage: swift draw-icon.swift <out.png>   (1024 x 1024; make-icon.sh builds the .icns)
import AppKit

let size: CGFloat = 1024
// Exactly 1024 px, whatever the screen's scale.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }

// macOS icon grid: an 824 pt rounded square centred on the canvas, with a soft shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
rgb(240, 30, 60).setFill()
shape.fill()
ctx.restoreGState()
ctx.saveGState()
shape.addClip()
NSGradient(colors: [rgb(255, 40, 40), rgb(250, 45, 85), rgb(225, 60, 170)])!.draw(in: tile, angle: -35)
ctx.restoreGState()

NSColor.white.setFill()

// Play symbol, with rounded corners, a little left of centre to leave room for the waves.
let c = CGPoint(x: 400, y: 512)
let play = NSBezierPath()
play.move(to: CGPoint(x: c.x - 110, y: c.y + 150))
play.line(to: CGPoint(x: c.x + 140, y: c.y))
play.line(to: CGPoint(x: c.x - 110, y: c.y - 150))
play.close()
play.lineJoinStyle = .round
play.lineWidth = 60
NSColor.white.setStroke()
play.fill()
play.stroke()

// Two radio waves going out from its tip.
for (i, radius) in [130, 230].enumerated() {
    let wave = NSBezierPath()
    wave.appendArc(withCenter: CGPoint(x: c.x + 110, y: c.y), radius: CGFloat(radius), startAngle: -42, endAngle: 42)
    wave.lineWidth = 52
    wave.lineCapStyle = .round
    NSColor.white.withAlphaComponent(i == 0 ? 1 : 0.7).setStroke()
    wave.stroke()
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
