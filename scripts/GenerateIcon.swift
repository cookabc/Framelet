import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        let background = NSBezierPath(
            roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
        NSGradient(
            starting: NSColor(red: 0.20, green: 0.52, blue: 0.44, alpha: 1),
            ending: NSColor(red: 0.08, green: 0.29, blue: 0.27, alpha: 1))!.draw(in: background, angle: -80)
        let frame = NSBezierPath()
        for (x, y, dx, dy) in [
            (280.0, 280.0, 1.0, 1.0), (744, 280, -1, 1), (280, 744, 1, -1), (744, 744, -1, -1),
        ] {
            frame.move(to: NSPoint(x: x, y: y + dy * 132))
            frame.line(to: NSPoint(x: x, y: y))
            frame.line(to: NSPoint(x: x + dx * 132, y: y))
        }
        frame.lineWidth = 45
        frame.lineCapStyle = .round
        frame.lineJoinStyle = .round
        NSColor(red: 0.94, green: 0.97, blue: 0.89, alpha: 1).setStroke()
        frame.stroke()
        NSColor(red: 0.99, green: 0.47, blue: 0.36, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 422, y: 422, width: 180, height: 180)).fill()
        image.unlockFocus()
        let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let png = representation.representation(using: .png, properties: [:])!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png.write(to: folder.appendingPathComponent(name))
    }
}
