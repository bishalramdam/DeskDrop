import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: generate_icon.swift <output_icns_path> [preview_png_path]\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: args[1])
let previewURL = args.count >= 3 ? URL(fileURLWithPath: args[2]) : nil
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

    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // Base macOS squircle
    let inset = size * 0.08
    let bgRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let bgRadius = bgRect.width * 0.225
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: bgRadius, cornerHeight: bgRadius, transform: nil)

    // Outer drop shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.022),
        blur: size * 0.045,
        color: NSColor.black.withAlphaComponent(0.32).cgColor
    )
    ctx.addPath(bgPath)
    ctx.setFillColor(NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.16, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Deep slate-navy background gradient + subtle glass rim
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let bgGradColors = [
        NSColor(calibratedRed: 0.11, green: 0.16, blue: 0.27, alpha: 1.0).cgColor, // #1C2945
        NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.14, alpha: 1.0).cgColor  // #0D1424
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgGradColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: bgRect.midX, y: bgRect.maxY),
            end: CGPoint(x: bgRect.midX, y: bgRect.minY),
            options: []
        )
    }

    // Soft ambient blue glow behind the cards
    let glowCenter = CGPoint(x: bgRect.midX - size * 0.04, y: bgRect.midY + size * 0.04)
    let glowColors = [
        NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 0.22).cgColor,
        NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 0.0).cgColor
    ] as CFArray
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            glow,
            startCenter: glowCenter,
            startRadius: 0,
            endCenter: glowCenter,
            endRadius: bgRect.width * 0.62,
            options: []
        )
    }

    // Subtle inner rim on background squircle
    ctx.addPath(bgPath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(max(1.0, size * 0.008))
    ctx.strokePath()
    ctx.restoreGState()

    // 1. Back Card (Desk / Mac screen) - bottom-right, frosted crisp light card
    let deskRect = CGRect(
        x: size * 0.36,
        y: size * 0.24,
        width: size * 0.42,
        height: size * 0.36
    )
    let deskRadius = size * 0.075
    let deskPath = CGPath(roundedRect: deskRect, cornerWidth: deskRadius, cornerHeight: deskRadius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.025),
        blur: size * 0.06,
        color: NSColor.black.withAlphaComponent(0.35).cgColor
    )
    ctx.addPath(deskPath)
    ctx.setFillColor(NSColor(calibratedRed: 0.95, green: 0.97, blue: 1.0, alpha: 0.94).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(deskPath)
    ctx.clip()
    let deskGradColors = [
        NSColor(calibratedRed: 0.99, green: 0.99, blue: 1.0, alpha: 0.96).cgColor,
        NSColor(calibratedRed: 0.87, green: 0.91, blue: 0.97, alpha: 0.94).cgColor
    ] as CFArray
    if let deskGrad = CGGradient(colorsSpace: colorSpace, colors: deskGradColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            deskGrad,
            start: CGPoint(x: deskRect.minX, y: deskRect.maxY),
            end: CGPoint(x: deskRect.maxX, y: deskRect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // 2. Front Card (Phone / Clip) - top-left overlapping, translucent Google Blue glass
    let phoneRect = CGRect(
        x: size * 0.22,
        y: size * 0.36,
        width: size * 0.34,
        height: size * 0.41
    )
    let phoneRadius = size * 0.075
    let phonePath = CGPath(roundedRect: phoneRect, cornerWidth: phoneRadius, cornerHeight: phoneRadius, transform: nil)

    // Soft cast shadow onto the desk card
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: size * 0.015, height: -size * 0.025),
        blur: size * 0.055,
        color: NSColor(calibratedRed: 0.04, green: 0.14, blue: 0.36, alpha: 0.45).cgColor
    )
    ctx.addPath(phonePath)
    ctx.setFillColor(NSColor(calibratedRed: 0.16, green: 0.46, blue: 0.94, alpha: 0.88).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(phonePath)
    ctx.clip()
    let phoneGradColors = [
        NSColor(calibratedRed: 0.44, green: 0.72, blue: 1.0, alpha: 0.88).cgColor, // Sky highlight #70B8FF
        NSColor(calibratedRed: 0.20, green: 0.50, blue: 0.96, alpha: 0.90).cgColor, // Google Blue #3380F5
        NSColor(calibratedRed: 0.10, green: 0.41, blue: 0.88, alpha: 0.94).cgColor  // Deep Blue #1A69E0
    ] as CFArray
    if let phoneGrad = CGGradient(colorsSpace: colorSpace, colors: phoneGradColors, locations: [0.0, 0.5, 1.0]) {
        ctx.drawLinearGradient(
            phoneGrad,
            start: CGPoint(x: phoneRect.minX, y: phoneRect.maxY),
            end: CGPoint(x: phoneRect.maxX, y: phoneRect.minY),
            options: []
        )
    }

    // Diagonal glass sheen on top-left of front card
    let sheenColors = [
        NSColor.white.withAlphaComponent(0.32).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor
    ] as CFArray
    if let sheen = CGGradient(colorsSpace: colorSpace, colors: sheenColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            sheen,
            start: CGPoint(x: phoneRect.minX, y: phoneRect.maxY),
            end: CGPoint(x: phoneRect.midX + phoneRect.width * 0.25, y: phoneRect.midY - phoneRect.height * 0.15),
            options: []
        )
    }
    ctx.restoreGState()

    // Crisp glass edge border on front card
    ctx.saveGState()
    ctx.addPath(phonePath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.48).cgColor)
    ctx.setLineWidth(max(1.0, size * 0.011))
    ctx.strokePath()
    ctx.restoreGState()

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
    if px == 512, let previewURL {
        try? png.write(to: previewURL, options: .atomic)
    }
}

var icns = Data("icns".utf8)
appendUInt32BE(&icns, UInt32(8 + body.count))
icns.append(body)

try icns.write(to: outputURL, options: .atomic)
