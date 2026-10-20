// Draws the icon of the macOS app: a phone showing the Android robot and "adb".
//
// Usage: swift release/make_icon.swift app/data/macos-icon.png
import AppKit

let size: CGFloat = 1024
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "macos-icon.png"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.set()
NSRect(x: 0, y: 0, width: size, height: size).fill()

// Background: macOS icon grid (824 px squircle-like shape with margin)
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -12)
NSGraphicsContext.saveGraphicsState()
shadow.set()
rgb(20, 30, 40).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [rgb(18, 44, 60), rgb(8, 122, 104)])!
    .draw(in: tilePath, angle: -60)

// Phone body
let phone = NSRect(x: 322, y: 190, width: 380, height: 650)
let body = NSBezierPath(roundedRect: phone, xRadius: 70, yRadius: 70)
NSGraphicsContext.saveGraphicsState()
let phoneShadow = NSShadow()
phoneShadow.shadowColor = NSColor(white: 0, alpha: 0.45)
phoneShadow.shadowBlurRadius = 30
phoneShadow.shadowOffset = NSSize(width: 0, height: -14)
phoneShadow.set()
rgb(16, 20, 24).setFill()
body.fill()
NSGraphicsContext.restoreGraphicsState()
rgb(120, 134, 146).setStroke()
body.lineWidth = 7
body.stroke()

// Screen
let screen = phone.insetBy(dx: 20, dy: 20)
let screenPath = NSBezierPath(roundedRect: screen, xRadius: 52, yRadius: 52)
NSGradient(colors: [rgb(9, 28, 40), rgb(4, 14, 22)])!
    .draw(in: screenPath, angle: -90)

// Camera cutout
rgb(0, 0, 0).setFill()
NSBezierPath(ovalIn: NSRect(x: 512 - 12, y: screen.maxY - 44, width: 24, height: 24)).fill()

// Android robot head
let green = rgb(61, 220, 132)
let cx: CGFloat = 512
let cy: CGFloat = 610
let r: CGFloat = 118
let head = NSBezierPath()
head.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r,
               startAngle: 0, endAngle: 180)
head.close()
green.setFill()
head.fill()

green.setStroke()
for side: CGFloat in [-1, 1] {
    let antenna = NSBezierPath()
    antenna.move(to: NSPoint(x: cx + side * 62, y: cy + 100))
    antenna.line(to: NSPoint(x: cx + side * 98, y: cy + 158))
    antenna.lineWidth = 11
    antenna.lineCapStyle = .round
    antenna.stroke()
}
rgb(8, 24, 34).setFill()
for side: CGFloat in [-1, 1] {
    NSBezierPath(ovalIn: NSRect(x: cx + side * 46 - 13, y: cy + 56, width: 26, height: 26)).fill()
}

// "adb" prompt
let font = NSFont.monospacedSystemFont(ofSize: 112, weight: .heavy)
let text = NSAttributedString(string: "adb", attributes: [
    .font: font, .foregroundColor: rgb(226, 255, 240)])
let textSize = text.size()
text.draw(at: NSPoint(x: cx - textSize.width / 2 - 14, y: 380))
// cursor
green.setFill()
NSBezierPath(roundedRect: NSRect(x: cx + textSize.width / 2 - 2, y: 392, width: 18, height: 84),
             xRadius: 4, yRadius: 4).fill()

// small status bar line at the bottom of the screen
rgb(255, 255, 255, 0.35).setFill()
NSBezierPath(roundedRect: NSRect(x: cx - 60, y: screen.minY + 22, width: 120, height: 8),
             xRadius: 4, yRadius: 4).fill()

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
