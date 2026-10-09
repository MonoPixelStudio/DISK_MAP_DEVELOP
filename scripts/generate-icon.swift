import AppKit

// A procedural disk map mark. All output is a project build product.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
guard !output.isSymbolicLink, output.deletingLastPathComponent().lastPathComponent == "dist" else {
    fatalError("Icon output must be inside the project dist folder")
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let colors = [NSColor(srgbRed: 0.35, green: 0.51, blue: 1, alpha: 1),
              NSColor(srgbRed: 0.62, green: 0.41, blue: 0.96, alpha: 1),
              NSColor(srgbRed: 0.15, green: 0.75, blue: 0.78, alpha: 1)]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.setFillColor(NSColor(srgbRed: 0.07, green: 0.10, blue: 0.18, alpha: 1).cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: 32, y: 32, width: 960, height: 960), cornerWidth: 212, cornerHeight: 212, transform: nil))
        context.fillPath()
        let center = CGPoint(x: 512, y: 512)
        for ring in 0..<3 {
            let inner = CGFloat(130 + ring * 100), outer = inner + 86
            for (segment, angles) in [(0, (0.05, 2.6)), (1, (2.65, 4.6)), (2, (4.65, 6.28))] {
                let path = CGMutablePath()
                path.addArc(center: center, radius: outer, startAngle: angles.0, endAngle: angles.1, clockwise: false)
                path.addArc(center: center, radius: inner, startAngle: angles.1, endAngle: angles.0, clockwise: true)
                path.closeSubpath()
                context.setFillColor(colors[segment].withAlphaComponent(1 - CGFloat(ring) * 0.12).cgColor)
                context.addPath(path); context.fillPath()
            }
        }
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let destination = output.appendingPathComponent(name)
        guard !destination.isSymbolicLink else { fatalError("Refused symlink icon output") }
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
    }
}

extension URL {
    var isSymbolicLink: Bool {
        (try? resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
