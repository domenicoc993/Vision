import AppKit

func createIconImage(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let scale = size / 1024.0

    // Canvas size 1024
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)

    // Shadow for squircle
    ctx.saveGState()
    let shadowColor = NSColor.black.withAlphaComponent(0.45).cgColor
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 36, color: shadowColor)

    // Base squircle
    let squircleRect = CGRect(x: 104, y: 104, width: 816, height: 816)
    let squirclePath = CGPath(roundedRect: squircleRect, cornerWidth: 184, cornerHeight: 184, transform: nil)
    ctx.addPath(squirclePath)
    ctx.setFillColor(NSColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Squircle gradient fill
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        NSColor(red: 0.14, green: 0.16, blue: 0.24, alpha: 1.0).cgColor,
        NSColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1.0).cgColor,
        NSColor(red: 0.04, green: 0.04, blue: 0.07, alpha: 1.0).cgColor
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 0.6, 1.0]
    if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
        ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 200, y: 900), end: CGPoint(x: 824, y: 104), options: [])
    }

    // Outer subtle border
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.setLineWidth(3.0)
    ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.18).cgColor)
    ctx.strokePath()
    ctx.restoreGState()

    // Inner glow / aperture circle behind glyph
    let center = CGPoint(x: 512, y: 512)
    let glowColors = [
        NSColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.28).cgColor,
        NSColor(red: 0.5, green: 0.1, blue: 0.9, alpha: 0.15).cgColor,
        NSColor.clear.cgColor
    ] as CFArray
    let glowLocations: [CGFloat] = [0.0, 0.5, 1.0]
    if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: glowLocations) {
        ctx.drawRadialGradient(glowGrad, startCenter: center, startRadius: 40, endCenter: center, endRadius: 360, options: [])
    }

    // Stylized Aperture / Lens Rings
    let outerRingRadius: CGFloat = 260
    ctx.saveGState()
    ctx.setLineWidth(14)
    ctx.setStrokeColor(NSColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.7).cgColor)
    ctx.strokeEllipse(in: CGRect(x: center.x - outerRingRadius, y: center.y - outerRingRadius, width: outerRingRadius * 2, height: outerRingRadius * 2))

    // Middle Ring with dash pattern (like film frames / lens markings)
    let midRingRadius: CGFloat = 220
    ctx.setLineWidth(5)
    let dashes: [CGFloat] = [18, 12]
    ctx.setLineDash(phase: 0, lengths: dashes)
    ctx.setStrokeColor(NSColor(red: 0.7, green: 0.4, blue: 1.0, alpha: 0.55).cgColor)
    ctx.strokeEllipse(in: CGRect(x: center.x - midRingRadius, y: center.y - midRingRadius, width: midRingRadius * 2, height: midRingRadius * 2))
    ctx.restoreGState()

    // Central Cinematic Play Triangle / Iris Eye
    ctx.saveGState()
    let trianglePath = CGMutablePath()
    // Triangle centered slightly adjusted for optical balance
    let triCenterX: CGFloat = 530
    let triCenterY: CGFloat = 512
    let triRadius: CGFloat = 135

    let p1 = CGPoint(x: triCenterX - triRadius * 0.75, y: triCenterY + triRadius * 1.05)
    let p2 = CGPoint(x: triCenterX + triRadius * 1.15, y: triCenterY)
    let p3 = CGPoint(x: triCenterX - triRadius * 0.75, y: triCenterY - triRadius * 1.05)

    // Rounded triangle
    let cornerRad: CGFloat = 26
    trianglePath.move(to: CGPoint(x: p1.x, y: p1.y - cornerRad))
    trianglePath.addArc(tangent1End: p1, tangent2End: p2, radius: cornerRad)
    trianglePath.addArc(tangent1End: p2, tangent2End: p3, radius: cornerRad)
    trianglePath.addArc(tangent1End: p3, tangent2End: p1, radius: cornerRad)
    trianglePath.closeSubpath()

    // Play button shadow
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor(red: 0.0, green: 0.8, blue: 1.0, alpha: 0.5).cgColor)
    ctx.addPath(trianglePath)
    ctx.clip()

    // Vibrant neon gradient inside Play symbol
    let playColors = [
        NSColor(red: 0.1, green: 0.95, blue: 1.0, alpha: 1.0).cgColor,
        NSColor(red: 0.2, green: 0.55, blue: 1.0, alpha: 1.0).cgColor,
        NSColor(red: 0.75, green: 0.15, blue: 0.95, alpha: 1.0).cgColor
    ] as CFArray
    let playLocations: [CGFloat] = [0.0, 0.45, 1.0]
    if let playGrad = CGGradient(colorsSpace: colorSpace, colors: playColors, locations: playLocations) {
        ctx.drawLinearGradient(playGrad, start: CGPoint(x: triCenterX - triRadius, y: triCenterY + triRadius), end: CGPoint(x: triCenterX + triRadius, y: triCenterY - triRadius), options: [])
    }
    ctx.restoreGState()

    // Glass reflection highlight on top edge of play button
    ctx.saveGState()
    ctx.addPath(trianglePath)
    ctx.setLineWidth(4)
    ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.45).cgColor)
    ctx.strokePath()
    ctx.restoreGState()

    // Bottom timeline dash track
    ctx.saveGState()
    let trackY: CGFloat = 200
    let trackWidth: CGFloat = 400
    let trackX: CGFloat = (1024 - trackWidth) / 2
    let trackPath = CGMutablePath()
    trackPath.addRoundedRect(in: CGRect(x: trackX, y: trackY, width: trackWidth, height: 10), cornerWidth: 5, cornerHeight: 5)
    ctx.addPath(trackPath)
    ctx.setFillColor(NSColor(white: 1.0, alpha: 0.15).cgColor)
    ctx.fillPath()

    // Playhead indicator needle
    let playheadX: CGFloat = trackX + trackWidth * 0.42
    let playheadPath = CGMutablePath()
    playheadPath.addRoundedRect(in: CGRect(x: playheadX - 3, y: trackY - 6, width: 6, height: 22), cornerWidth: 3, cornerHeight: 3)
    ctx.addPath(playheadPath)
    ctx.setFillColor(NSColor(red: 0.0, green: 0.95, blue: 1.0, alpha: 0.9).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.restoreGState() // restore scale

    image.unlockFocus()
    return image
}

func savePNG(image: NSImage, targetSize: Int, url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: targetSize,
        pixelsHigh: targetSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.interpolationQuality = .high

    image.draw(in: NSRect(x: 0, y: 0, width: targetSize, height: targetSize),
               from: .zero,
               operation: .copy,
               fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()

    if let pngData = rep.representation(using: .png, properties: [:]) {
        try? pngData.write(to: url)
    }
}

let fileManager = FileManager.default
let iconsetDir = URL(fileURLWithPath: "Resources/Vision.iconset")
try? fileManager.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let masterImage = createIconImage(size: 1024)

let iconSpecs: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for spec in iconSpecs {
    let destURL = iconsetDir.appendingPathComponent(spec.name)
    savePNG(image: masterImage, targetSize: spec.size, url: destURL)
    print("Generated: \(spec.name) (\(spec.size)x\(spec.size))")
}

print("Iconset created successfully.")
