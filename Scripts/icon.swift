import AppKit

let target = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = NSImage(contentsOfFile: "Resources/AppIcon.png") else {
    fatalError("无法加载 Resources/AppIcon.png")
}
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let inset = CGFloat(pixels) * 0.08
        let tile = NSRect(x: inset, y: inset, width: CGFloat(pixels) - 2 * inset, height: CGFloat(pixels) - 2 * inset)
        NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.height * 0.22).addClip()
        source.draw(in: tile)
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent(filename))
    }
}
