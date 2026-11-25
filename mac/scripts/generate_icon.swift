import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: generate_icon.swift <output_icns_path>\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data? {
    let size = CGFloat(pixelSize)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }

    let inset = size * 0.08
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.02),
        blur: size * 0.04,
        color: NSColor.black.withAlphaComponent(0.22).cgColor
    )
    ctx.addPath(path)
    ctx.setFillColor(NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.91, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill + Google 4-color bottom accent
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradColors = [
        NSColor(calibratedRed: 0.26, green: 0.52, blue: 0.96, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.91, alpha: 1.0).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    let barHeight = rect.height * 0.085
    let segWidth = rect.width / 4.0
    let googleColors: [NSColor] = [
        NSColor(calibratedRed: 0.26, green: 0.52, blue: 0.96, alpha: 1.0), // Blue #4285F4
        NSColor(calibratedRed: 0.92, green: 0.26, blue: 0.21, alpha: 1.0), // Red #EA4335
        NSColor(calibratedRed: 0.98, green: 0.74, blue: 0.02, alpha: 1.0), // Yellow #FBBC05
        NSColor(calibratedRed: 0.20, green: 0.66, blue: 0.33, alpha: 1.0)  // Green #34A853
    ]
    for (i, color) in googleColors.enumerated() {
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: rect.minX + CGFloat(i) * segWidth, y: rect.minY, width: segWidth + 1, height: barHeight))
    }
    ctx.restoreGState()

    // White SF Symbol matching the menu bar panel icon
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: size * 0.44, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig) {
        let symSize = symbol.size
        let symRect = CGRect(
            x: (size - symSize.width) / 2.0,
            y: (size - symSize.height) / 2.0 + size * 0.02,
            width: symSize.width,
            height: symSize.height
        )
        symbol.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
    var be = value.bigEndian
    data.append(Data(bytes: &be, count: 4))
}

let chunks: [(String, Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024)
]

var body = Data()
for (osType, px) in chunks {
    guard let png = renderIcon(pixelSize: px) else { continue }
    body.append(Data(osType.utf8))
    appendUInt32BE(&body, UInt32(8 + png.count))
    body.append(png)
}

var icns = Data("icns".utf8)
appendUInt32BE(&icns, UInt32(8 + body.count))
icns.append(body)

try icns.write(to: outputURL, options: .atomic)
