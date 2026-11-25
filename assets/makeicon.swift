// Deterministic vector rendering of the MacFlac icon: graphite glass tile with a blue waveform.
// Usage: swift assets/makeicon.swift output.png [size]
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let pixels = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1024 : 1024
guard pixels > 0, pixels <= 4096 else { fatalError("Icon size must be 1...4096") }
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon") }
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func gradient(_ path: NSBezierPath, _ colors: [NSColor], angle: CGFloat = -90) {
    NSGradient(colors: colors)!.draw(in: path, angle: angle)
}
func withShadow(blur: CGFloat, offset: CGFloat, alpha: CGFloat, draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: offset)
    shadow.set(); draw()
    NSGraphicsContext.restoreGraphicsState()
}
func bezier(_ cgPath: CGPath) -> NSBezierPath {
    let path = NSBezierPath()
    cgPath.applyWithBlock { item in
        let e = item.pointee
        switch e.type {
        case .moveToPoint: path.move(to: e.points[0])
        case .addLineToPoint: path.line(to: e.points[0])
        case .addCurveToPoint: path.curve(to: e.points[2], controlPoint1: e.points[0], controlPoint2: e.points[1])
        case .closeSubpath: path.close()
        default: break
        }
    }
    return path
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 184, yRadius: 184)
withShadow(blur: 16, offset: -9, alpha: 0.13) {
    gradient(tile, [color(0x303239), color(0x23252B), color(0x17191E)], angle: -65)
}
color(0xFFFFFF, 0.14).setStroke(); tile.lineWidth = 3; tile.stroke()
let inset = NSBezierPath(roundedRect: NSRect(x: 107, y: 107, width: 810, height: 810), xRadius: 177, yRadius: 177)
color(0xFFFFFF, 0.05).setStroke(); inset.lineWidth = 1.5; inset.stroke()

// Seven rounded bars forming a waveform, tallest in the middle.
let heights: [CGFloat] = [190, 370, 540, 300, 620, 380, 210]
let strokes = CGMutablePath()
let left: CGFloat = 270, step: CGFloat = 80.7
for (i, h) in heights.enumerated() {
    let x = left + step * CGFloat(i)
    strokes.move(to: CGPoint(x: x, y: 512 - h / 2))
    strokes.addLine(to: CGPoint(x: x, y: 512 + h / 2))
}
let lineWidth: CGFloat = pixels <= 32 ? 58 : 50
let mark = bezier(strokes.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 1))
withShadow(blur: 7, offset: -4, alpha: 0.12) {
    gradient(mark, [color(0x24B5FF), color(0x098AF6), color(0x086BE9)])
}
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
do { try png.write(to: URL(fileURLWithPath: output)) }
catch { fputs("Cannot write icon: \(error)\n", stderr); exit(1) }
