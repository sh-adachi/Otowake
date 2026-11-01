import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var iconChunks = Data()
func be32(_ n: UInt32) -> Data { var value = n.bigEndian; return Data(bytes: &value, count: 4) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let s = CGFloat(pixels)
        let tile = NSBezierPath(roundedRect: NSRect(x: s * 0.07, y: s * 0.07, width: s * 0.86, height: s * 0.86), xRadius: s * 0.2, yRadius: s * 0.2)
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.62, blue: 0.56, alpha: 1),
                   ending: NSColor(calibratedRed: 0.05, green: 0.32, blue: 0.34, alpha: 1))!.draw(in: tile, angle: -70)
        NSColor.white.setStroke()
        let heights: [CGFloat] = [0.16, 0.34, 0.49, 0.26, 0.40]
        for (i, height) in heights.enumerated() {
            let x = s * (0.27 + CGFloat(i) * 0.115)
            let line = NSBezierPath(); line.lineCapStyle = .round; line.lineWidth = s * 0.048
            line.move(to: NSPoint(x: x, y: s * (0.5 - height / 2)))
            line.line(to: NSPoint(x: x, y: s * (0.5 + height / 2))); line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: directory.appendingPathComponent(name))
        let types = [16: ["icp4", "ic11"], 32: ["icp5", "ic12"], 128: ["ic07", "ic13"], 256: ["ic08", "ic14"], 512: ["ic09", "ic10"]]
        iconChunks.append(contentsOf: types[size]![scale - 1].utf8)
        iconChunks.append(be32(UInt32(png.count + 8))); iconChunks.append(png)
    }
}
var icns = Data("icns".utf8); icns.append(be32(UInt32(iconChunks.count + 8))); icns.append(iconChunks)
try icns.write(to: directory.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))
