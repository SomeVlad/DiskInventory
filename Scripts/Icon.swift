import AppKit

let output = URL(filePath: CommandLine.arguments[1], directoryHint: .notDirectory)
let tiles: [(CGRect, UInt32)] = [
    (CGRect(x: 221, y: 365, width: 320, height: 417), 0x55B4DB),
    (CGRect(x: 557, y: 551, width: 245, height: 231), 0x75AE8E),
    (CGRect(x: 557, y: 365, width: 245, height: 170), 0xE3B76A),
    (CGRect(x: 221, y: 242, width: 198, height: 107), 0xC88372),
    (CGRect(x: 435, y: 242, width: 107, height: 107), 0x708EC9),
    (CGRect(x: 558, y: 242, width: 244, height: 107), 0x417B96)
]

func color(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1)
}

func render(_ size: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: rep) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let plate = NSBezierPath(roundedRect: CGRect(x: 102, y: 102, width: 820, height: 820), xRadius: 187, yRadius: 187)
    NSGradient(starting: color(0x3D6276), ending: color(0x172938))?.draw(in: plate, angle: -89)
    color(0x597486).setStroke()
    plate.lineWidth = 8
    plate.stroke()
    color(0x192A35).setFill()
    NSBezierPath(roundedRect: CGRect(x: 196, y: 214, width: 632, height: 594), xRadius: 34, yRadius: 34).fill()
    for (box, rgb) in tiles {
        color(rgb).setFill()
        NSBezierPath(roundedRect: box, xRadius: 13, yRadius: 13).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return png
}

func appendLength(_ length: Int, to data: inout Data) {
    var bigEndian = UInt32(length).bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

let variants: [(String, Int)] = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
    ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)
]
var chunks = Data()
for (type, dimension) in variants {
    let payload = try render(dimension)
    chunks.append(contentsOf: type.utf8)
    appendLength(payload.count + 8, to: &chunks)
    chunks.append(payload)
}
var file = Data("icns".utf8)
appendLength(chunks.count + 8, to: &file)
file.append(chunks)
try file.write(to: output, options: .atomic)
