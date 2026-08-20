#!/usr/bin/env swift
import AppKit

// Renders Koda Player's app icon into an .iconset directory, which build-app.sh packs
// with iconutil.
//
// The icon is the app's pitch as a picture: a prism throwing a spectrum. Koda takes
// anything — MKV, AVI, VOB, RMVB, whatever else FFmpeg can demux — and turns it into one
// picture. A right-pointing play triangle happens to be the same shape as a prism, so the
// button and the idea are one mark.

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// MARK: - Grid
//
// Measured off Apple's own icons rather than guessed at: filling a 1024 canvas with an
// 814pt body and a 21.6% corner radius disagrees with Music.app's silhouette on 0.23% of
// pixels. Getting this wrong is what makes a third-party icon sit oddly in the Dock.

let bodyRatio: CGFloat = 814.0 / 1024.0
let cornerRatio: CGFloat = 0.216

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func tilePath(in rect: NSRect) -> NSBezierPath {
    let radius = rect.width * cornerRatio
    return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

/// The prism: an equilateral play triangle with rounded joins, nudged right so it reads as
/// centred. Its vertices are returned too, because the light has to meet its faces.
func prism(center: NSPoint, radius: CGFloat, cornerRadius: CGFloat) -> (path: NSBezierPath, points: [NSPoint]) {
    let c = NSPoint(x: center.x + radius * 0.10, y: center.y)
    let points = (0..<3).map { index -> NSPoint in
        let angle = CGFloat(index) * (2 * .pi / 3)
        return NSPoint(x: c.x + radius * cos(angle), y: c.y + radius * sin(angle))
    }
    let path = NSBezierPath()
    path.move(to: NSPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2))
    path.appendArc(from: points[1], to: points[2], radius: cornerRadius)
    path.appendArc(from: points[2], to: points[0], radius: cornerRadius)
    path.appendArc(from: points[0], to: points[1], radius: cornerRadius)
    path.close()
    return (path, points)
}

/// Rim light fading from the top edge down. Clipping a stroke to the top half leaves a
/// visible notch where the clip ends; masking the stroke with a gradient does not.
func drawRim(in rect: NSRect, canvas: CGFloat) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let inset = rect.insetBy(dx: canvas * 0.004, dy: canvas * 0.004)
    let radius = inset.width * cornerRatio
    let outline = CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let stroked = outline.copy(strokingWithWidth: canvas * 0.007, lineCap: .round, lineJoin: .round, miterLimit: 10)
    context.saveGState()
    context.addPath(stroked)
    context.clip()
    NSGradient(colors: [color(0xFFFFFF, 0.20), color(0xFFFFFF, 0)])?.draw(in: rect, angle: -90)
    context.restoreGState()
}

private enum Detail {
    /// 128pt and up: beam, refraction, seven bands.
    case full
    /// 32 and 64pt: no beam — it is a pixel wide there — but still glass and colour.
    case medium
    /// 16pt: a lifted tile, a white mark, four blocks of colour.
    case plain
}

// MARK: - The icon

/// Drawn straight into a bitmap of the exact pixel size. Going through `NSImage.lockFocus`
/// renders at the display's backing scale instead, which silently produced every slot at
/// double its declared size — and a 16pt icon downsampled from 32px is a blurry one.
func drawIcon(pixels: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = pixels
    // One threshold was not enough. The beam is only a pixel wide at 64pt, where it
    // aliases into a smear, so it goes; below 32 the dispersion has to become a few solid
    // blocks or it turns to mud. What survives at every size is the same picture: a dark
    // tile, a white play mark, colour leaving it to the lower right.
    let detail: Detail = pixels >= 128 ? .full : (pixels >= 32 ? .medium : .plain)
    let detailed = detail == .full

    let body = size * bodyRatio
    let rect = NSRect(x: (size - body) / 2, y: (size - body) / 2, width: body, height: body)
    let tile = tilePath(in: rect)
    let center = NSPoint(x: rect.midX, y: rect.midY)

    // Scoped to the tile on purpose: left set, this shadow also falls on the beam and on
    // every band of the spectrum, which is what turned the colours muddy.
    NSGraphicsContext.saveGraphicsState()
    if detail != .plain {
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
        shadow.shadowBlurRadius = size * 0.028
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.set()
    }
    // A near-black tile disappears into a dark Dock at the smallest sizes, where there is
    // no bloom left to separate it.
    let tileColors = detail == .plain
        ? [color(0x2A2F3E), color(0x14171F)]
        : [color(0x161A24), color(0x080910)]
    NSGradient(colors: tileColors)?.draw(in: tile, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Sized for the Dock, which is where this icon is actually looked at.
    let glass = prism(center: center,
                      radius: body * (detail == .full ? 0.37 : 0.40),
                      cornerRadius: body * 0.045)

    // Where the colour leaves the glass, taken from the glyph's own vertices so the
    // spectrum starts on a face rather than floating beside one.
    let apex = glass.points[0]
    let bottomLeft = glass.points[2]
    let exit = NSPoint(x: apex.x + (bottomLeft.x - apex.x) * 0.46,
                       y: apex.y + (bottomLeft.y - apex.y) * 0.46)

    // The far face split into its colours, running off the tile. Fewer, more
    // saturated bands as the icon shrinks: seven of them inside 12 pixels is grey.
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let bands: [UInt32]
    switch detail {
    case .full: bands = [0xFF453A, 0xFF9F0A, 0xFFD426, 0x30D158, 0x40C8E0, 0x0A84FF, 0xBF5AF2]
    case .medium: bands = [0xFF453A, 0xFFD426, 0x30D158, 0x0A84FF, 0xBF5AF2]
    case .plain: bands = [0xFF453A, 0xFFD426, 0x30D158, 0x0A84FF]
    }
    let spread: CGFloat = (detail == .full ? 42 : 44) * .pi / 180
    let first: CGFloat = -14 * .pi / 180
    let reach = body * 1.4
    for (index, band) in bands.enumerated() {
        let t0 = first - spread * CGFloat(index) / CGFloat(bands.count)
        let t1 = first - spread * CGFloat(index + 1) / CGFloat(bands.count)
        let wedge = NSBezierPath()
        wedge.move(to: exit)
        wedge.line(to: NSPoint(x: exit.x + reach * cos(t0), y: exit.y + reach * sin(t0)))
        wedge.line(to: NSPoint(x: exit.x + reach * cos(t1), y: exit.y + reach * sin(t1)))
        wedge.close()
        NSGraphicsContext.current?.compositingOperation = .plusLighter
        let fade: [NSColor] = detail == .full
            ? [color(band, 1.0), color(band, 0.72), color(band, 0.06)]
            : [color(band, 1.0), color(band, 0.85), color(band, 0.35)]
        NSGradient(colors: fade)?.draw(in: wedge, angle: -32)
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    if detailed {
        let glow = NSShadow()
        glow.shadowOffset = .zero
        glow.shadowBlurRadius = size * 0.045
        glow.shadowColor = color(0x9B7BFF, 0.75)
        glow.set()
        NSGradient(colors: [color(0xFFFFFF, 0.97), color(0xC9BEFF, 0.80)])?
            .draw(in: glass.path, angle: -100)

    } else {
        // Flat white rather than a tinted gradient: at these sizes a gradient reads as
        // dirt, and the small icon has to look like the big one.
        color(0xFFFFFF).setFill()
        glass.path.fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    if detailed {
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        drawRim(in: rect, canvas: size)
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    guard let png = drawIcon(pixels: variant.pixels).representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try png.write(to: outputDirectory.appendingPathComponent("\(variant.name).png"))
}
