import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let center = CGPoint(x: canvas / 2, y: canvas / 2)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let coverage: CGFloat = 0.90

let orbitRadiusX: CGFloat = 492
let orbitRadiusY: CGFloat = 95
let strokeWidth: CGFloat = 38
let knockoutGap: CGFloat = 22
let ringOuterRadius: CGFloat = 219
let ringBand: CGFloat = 48
let coreRadius: CGFloat = 137
let orbitAngle: CGFloat = -21
let orbitShiftY: CGFloat = -44

enum Element: String, CaseIterable {
    case orbitBack = "Orbit Back"
    case sphereRing = "Sphere Ring"
    case sphereCore = "Sphere Core"
    case orbitFront = "Orbit Front"

    var fileName: String {
        rawValue.lowercased().replacingOccurrences(of: " ", with: "-") + ".png"
    }

    var depth: Double {
        switch self {
        case .orbitBack: 0.40
        case .sphereRing: 0.70
        case .sphereCore: 0.90
        case .orbitFront: 1.00
        }
    }

    var translucency: Double {
        switch self {
        case .orbitBack: 0.30
        case .sphereRing: 0.35
        case .sphereCore: 0.50
        case .orbitFront: 0.30
        }
    }
}

func makeContext(size: CGFloat) -> CGContext {
    let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    return context
}

func circle(_ radius: CGFloat) -> CGRect {
    CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
    )
}

func orbitFrame() -> CGAffineTransform {
    CGAffineTransform(translationX: center.x, y: center.y + orbitShiftY)
        .rotated(by: orbitAngle * .pi / 180)
}

func orbitPath() -> CGPath {
    var transform = orbitFrame()
    let box = CGRect(
        x: -orbitRadiusX,
        y: -orbitRadiusY,
        width: orbitRadiusX * 2,
        height: orbitRadiusY * 2
    )
    return CGPath(ellipseIn: box, transform: &transform)
}

func halfPlane(front: Bool) -> CGPath {
    let big = canvas * 2
    let overlap: CGFloat = 6
    let rect = front
        ? CGRect(x: -big, y: -big, width: big * 2, height: big + overlap)
        : CGRect(x: -big, y: -overlap, width: big * 2, height: big + overlap)
    var transform = orbitFrame()
    return CGPath(rect: rect, transform: &transform)
}

func strokeHalf(front: Bool, into context: CGContext) {
    context.saveGState()
    context.addPath(halfPlane(front: front))
    context.clip()
    context.setLineWidth(strokeWidth)
    context.addPath(orbitPath())
    context.strokePath()
    context.restoreGState()
}

func cutNearHalf(from context: CGContext) {
    context.saveGState()
    context.addPath(halfPlane(front: true))
    context.clip()
    context.setBlendMode(.clear)
    context.setLineWidth(strokeWidth + knockoutGap * 2)
    context.addPath(orbitPath())
    context.strokePath()
    context.restoreGState()
}

func draw(_ element: Element, into context: CGContext) {
    context.setStrokeColor(white)
    context.setFillColor(white)

    switch element {
    case .orbitBack:
        strokeHalf(front: false, into: context)
        context.setBlendMode(.clear)
        context.fillEllipse(in: circle(ringOuterRadius + knockoutGap))
        context.setBlendMode(.normal)

    case .sphereRing:
        context.setLineWidth(ringBand)
        context.strokeEllipse(in: circle(ringOuterRadius - ringBand / 2))
        cutNearHalf(from: context)

    case .sphereCore:
        context.fillEllipse(in: circle(coreRadius))
        cutNearHalf(from: context)

    case .orbitFront:
        strokeHalf(front: true, into: context)
    }
}

func render(_ elements: [Element]) -> CGImage {
    let context = makeContext(size: canvas)
    for element in elements {
        draw(element, into: context)
    }
    return context.makeImage()!
}

func inkBounds(_ image: CGImage) -> CGRect {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
        let scan = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        scan.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else {
        return CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    }
    return CGRect(
        x: CGFloat(minX),
        y: CGFloat(minY),
        width: CGFloat(maxX - minX + 1),
        height: CGFloat(maxY - minY + 1)
    )
}

func normalized(_ image: CGImage, sharedInk ink: CGRect) -> CGImage {
    let scale = canvas * coverage / max(ink.width, ink.height)
    let context = makeContext(size: canvas)
    context.translateBy(x: canvas / 2, y: canvas / 2)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -ink.midX, y: -ink.midY)
    context.draw(image, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

func group(for element: Element) -> [String: Any] {
    [
        "blur-material": NSNull(),
        "layers": [
            [
                "fill": ["solid": "srgb:1.00000,1.00000,1.00000,1.00000"],
                "image-name": element.fileName,
                "name": element.rawValue,
            ]
        ],
        "opacity": 1,
        "refractivity": ["depth": element.depth, "enabled": true, "strength": 0.005],
        "shadow": ["kind": "neutral", "opacity": 0.5],
        "specular": "inside",
        "translucency": ["enabled": true, "value": element.translucency],
    ]
}

// A conventional iconset works with macOS 15's iconutil and does not require
// the macOS 26 Icon Composer format or actool from a full Xcode installation.
func writeIconset(to root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let context = makeContext(size: canvas)
    let background = CGRect(x: 64, y: 64, width: 896, height: 896)
    context.saveGState()
    context.addPath(CGPath(
        roundedRect: background, cornerWidth: 200, cornerHeight: 200, transform: nil))
    context.clip()
    let colors = [
        CGColor(red: 0.25882, green: 0.25882, blue: 0.26667, alpha: 1),
        CGColor(red: 0.12549, green: 0.12549, blue: 0.13333, alpha: 1),
    ]
    let gradient = CGGradient(
        colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 512, y: 960), end: CGPoint(x: 512, y: 64), options: [])
    context.restoreGState()
    let artwork = render(Element.allCases)
    let symbol = normalized(artwork, sharedInk: inkBounds(artwork))
    context.draw(symbol, in: CGRect(x: 112, y: 112, width: 800, height: 800))
    let image = context.makeImage()!
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = CGFloat(size * scale)
            let resized = makeContext(size: pixels)
            resized.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            let suffix = scale == 2 ? "@2x" : ""
            try write(resized.makeImage()!, to: root.appendingPathComponent(
                "icon_\(size)x\(size)\(suffix).png"))
        }
    }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--iconset" {
    try writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
    exit(0)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: icon <output.icon> | --iconset <output.iconset>\n".data(using: .utf8)!)
    exit(2)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
try? FileManager.default.removeItem(at: root)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let sharedInk = inkBounds(render(Element.allCases))
for element in Element.allCases {
    let layer = normalized(render([element]), sharedInk: sharedInk)
    try write(layer, to: assets.appendingPathComponent(element.fileName))
}

let document: [String: Any] = [
    "features": ["refractivity", "specular-location"],
    "fill": [
        "linear-gradient": [
            "srgb:0.25882,0.25882,0.26667,1.00000",
            "srgb:0.12549,0.12549,0.13333,1.00000",
        ]
    ],
    "groups": Element.allCases.map(group(for:)),
    "supported-platforms": ["circles": ["watchOS"], "squares": "shared"],
]
try JSONSerialization
    .data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    .write(to: root.appendingPathComponent("icon.json"))
