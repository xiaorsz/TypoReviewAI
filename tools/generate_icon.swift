import AppKit

// Code-native book + sparkle mark; opaque 1024px source for all iOS icon sizes.
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let background = NSBezierPath(rect: NSRect(origin: .zero, size: size))
NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.29, alpha: 1),
           ending: NSColor(calibratedRed: 0.33, green: 0.31, blue: 0.75, alpha: 1))!.draw(in: background, angle: 45)
NSColor(calibratedRed: 0.47, green: 0.88, blue: 0.78, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 220, y: 220, width: 510, height: 555), xRadius: 65, yRadius: 65).fill()
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 256, y: 260, width: 478, height: 510), xRadius: 45, yRadius: 45).fill()
NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.29, alpha: 1).setFill()
for (y, width) in [(640.0, 280.0), (550.0, 235.0), (460.0, 190.0)] {
    NSBezierPath(roundedRect: NSRect(x: 330, y: y, width: width, height: 24), xRadius: 12, yRadius: 12).fill()
}
func star(x: CGFloat, y: CGFloat, r: CGFloat) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x, y: y + r))
    p.line(to: NSPoint(x: x + r * 0.26, y: y + r * 0.26))
    p.line(to: NSPoint(x: x + r, y: y))
    p.line(to: NSPoint(x: x + r * 0.26, y: y - r * 0.26))
    p.line(to: NSPoint(x: x, y: y - r))
    p.line(to: NSPoint(x: x - r * 0.26, y: y - r * 0.26))
    p.line(to: NSPoint(x: x - r, y: y))
    p.line(to: NSPoint(x: x - r * 0.26, y: y + r * 0.26))
    p.close(); p.fill()
}
NSColor(calibratedRed: 0.99, green: 0.80, blue: 0.39, alpha: 1).setFill()
star(x: 735, y: 730, r: 145)
NSColor.white.setFill(); star(x: 835, y: 865, r: 43)
image.unlockFocus()
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
