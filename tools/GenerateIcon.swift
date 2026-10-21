import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func render(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    NSColor(calibratedRed: 0.98, green: 0.88, blue: 0.60, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 58, y: 58, width: 908, height: 908), xRadius: 210, yRadius: 210).fill()
    let paper = NSBezierPath(roundedRect: NSRect(x: 228, y: 173, width: 576, height: 680), xRadius: 64, yRadius: 64)
    NSColor(calibratedWhite: 1, alpha: 0.97).setFill()
    paper.fill()
    NSColor(calibratedRed: 0.97, green: 0.69, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 228, y: 697, width: 576, height: 156), xRadius: 64, yRadius: 64).fill()
    NSBezierPath(rect: NSRect(x: 228, y: 697, width: 576, height: 70)).fill()
    NSColor(calibratedRed: 0.77, green: 0.74, blue: 0.67, alpha: 0.65).setFill()
    for (y, width) in [(596.0, 364.0), (489.0, 364.0), (382.0, 252.0)] {
        NSBezierPath(roundedRect: NSRect(x: 319, y: y, width: width, height: 22), xRadius: 11, yRadius: 11).fill()
    }
    NSColor(calibratedRed: 0.27, green: 0.25, blue: 0.21, alpha: 1).setFill()
    let pen = NSBezierPath()
    pen.move(to: NSPoint(x: 592, y: 222))
    pen.line(to: NSPoint(x: 684, y: 244))
    pen.line(to: NSPoint(x: 865, y: 429))
    pen.curve(to: NSPoint(x: 798, y: 493), controlPoint1: NSPoint(x: 902, y: 466), controlPoint2: NSPoint(x: 839, y: 526))
    pen.line(to: NSPoint(x: 616, y: 307))
    pen.close()
    pen.fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for pointSize in [16, 32, 128, 256, 512] {
    try render(size: pointSize).write(to: destination.appendingPathComponent("icon_\(pointSize)x\(pointSize).png"))
    try render(size: pointSize * 2).write(to: destination.appendingPathComponent("icon_\(pointSize)x\(pointSize)@2x.png"))
}
