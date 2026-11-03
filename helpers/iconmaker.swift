// Reads an image and produces a macOS .icns masked to the continuous rounded
// rect (squircle) that native app icons use. Input is scaled to fill 1024x1024
// and clipped. Output covers 16x16 through 512x512@2x.
// Usage: iconmaker <input-image|input.exe> <output.icns>
//        iconmaker --shortcuts <appid> <icon.icns> <stock.icns>

import AppKit
import Foundation

if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--shortcuts" {
    np_shortcuts_icons(getenv("HOME"), CommandLine.arguments[2], CommandLine.arguments[3], CommandLine.arguments[4])
    exit(0)
}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: iconmaker <input-image|input.exe> <output.icns>\n", stderr)
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

private func loadImage(_ path: String) -> NSImage? {
    var length = 0
    if let raw = np_pe_icon_ico(path, &length) {
        let ico = Data(bytesNoCopy: raw, count: length, deallocator: .free)
        if !ico.isEmpty, let image = readable(NSImage(data: ico)) ?? icoEntry(ico) {
            FileHandle.standardError.write(Data("iconmaker: using icon from PE resources\n".utf8))
            return image
        }
    }
    return readable(NSImage(contentsOfFile: path)) ?? FileManager.default.contents(atPath: path).flatMap(icoEntry)
}

private func readable(_ image: NSImage?) -> NSImage? {
    image.flatMap { hasArea($0) ? $0 : nil }
}

// ImageIO rejects a whole .ico over one entry it can't decode
private func icoEntry(_ data: Data) -> NSImage? {
    let b = [UInt8](data)
    guard b.count >= 6, b[0...3] == [0, 0, 1, 0] else { return nil }
    let count = Int(b[4]) | Int(b[5]) << 8
    guard b.count >= 6 + 16 * count else { return nil }
    func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
    func side(_ e: Int) -> Int { b[e] == 0 ? 256 : Int(b[e]) }
    for e in (0..<count).map({ 6 + 16 * $0 }).sorted(by: { side($0) > side($1) }) {
        let size = u32(e + 8), offset = u32(e + 12)
        guard size > 0, offset + size <= b.count else { continue }
        let one = [0, 0, 1, 0, 1, 0] + b[e..<e + 8] + withUnsafeBytes(of: UInt32(size).littleEndian, Array.init)
            + withUnsafeBytes(of: UInt32(22).littleEndian, Array.init) + b[offset..<offset + size]
        if let image = readable(NSImage(data: Data(one))) { return image }
    }
    return nil
}

private func hasArea(_ image: NSImage) -> Bool {
    image.size.width > 0 && image.size.height > 0
        && image.size.width.isFinite && image.size.height.isFinite
}

guard let srcImage = loadImage(inputPath), hasArea(srcImage) else {
    fputs("iconmaker: cannot read \(inputPath)\n", stderr)
    exit(1)
}

// The Apple icon grid puts the squircle corner radius at ~22.37% of the
// icon side. NSBezierPath.init(roundedRect:xRadius:yRadius:) draws a
// continuous rounded rect on macOS 14+, which is the shape Finder uses.
let maskRadius: CGFloat = 0.2237

let sizes: [(side: Int, scale: Int, name: String)] = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

let fm = FileManager.default
let iconsetURL: URL
if #available(macOS 13.0, *) {
    iconsetURL = URL(filePath: outputPath + ".iconset")
} else {
    iconsetURL = URL(fileURLWithPath: outputPath + ".iconset")
}
try? fm.removeItem(at: iconsetURL)
try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for entry in sizes {
    let px = entry.side * entry.scale
    let s = CGFloat(px)
    let r = s * maskRadius

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx

    // Clip to the squircle, then draw the source image scaled to fill.
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
    path.addClip()

    // Scale-to-fill: pick the scale that covers the canvas on both axes,
    // then center the overflow.
    let srcSize = srcImage.size
    let scale = max(s / srcSize.width, s / srcSize.height)
    let drawW = srcSize.width * scale
    let drawH = srcSize.height * scale
    let drawRect = NSRect(
        x: (s - drawW) / 2, y: (s - drawH) / 2,
        width: drawW, height: drawH
    )
    srcImage.draw(in: drawRect)

    ctx.flushGraphics()
    NSGraphicsContext.current = nil

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fputs("iconmaker: failed to render \(entry.name)\n", stderr)
        exit(1)
    }

    let fileURL: URL
    if #available(macOS 13.0, *) {
        fileURL = iconsetURL.appending(path: entry.name)
    } else {
        fileURL = iconsetURL.appendingPathComponent(entry.name)
    }
    try png.write(to: fileURL)
}

// iconutil produces the .icns from the populated iconset directory.
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetURL.path, "-o", outputPath]
try proc.run()
proc.waitUntilExit()

// Clean up the intermediate iconset.
try? fm.removeItem(at: iconsetURL)

if proc.terminationStatus != 0 {
    fputs("iconmaker: iconutil failed with status \(proc.terminationStatus)\n", stderr)
    exit(1)
}
