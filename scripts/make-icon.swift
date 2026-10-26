import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Same paths as Assets/AppIcon.svg, drawn into a vector PDF and the sizes macOS
// requires in an ICNS. Coordinates are kept in SVG's top-left convention.
func draw(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(CGColor(red: 18/255, green: 52/255, blue: 75/255, alpha: 1))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864), cornerWidth: 180, cornerHeight: 180, transform: nil)); ctx.fillPath()
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 286, y: 206, width: 452, height: 612), cornerWidth: 36, cornerHeight: 36, transform: nil)); ctx.fillPath()
    ctx.setStrokeColor(CGColor(red: 140/255, green: 160/255, blue: 173/255, alpha: 1))
    ctx.setLineWidth(22); ctx.setLineCap(.round)
    for (y, end) in [(398, 654), (470, 654), (542, 654), (614, 578)] {
        ctx.move(to: CGPoint(x: 370, y: y)); ctx.addLine(to: CGPoint(x: end, y: y)); ctx.strokePath()
    }
    ctx.setStrokeColor(CGColor(red: 57/255, green: 215/255, blue: 237/255, alpha: 1))
    ctx.setLineWidth(30); ctx.setLineJoin(.round)
    for points in [
        [CGPoint(x: 224, y: 350), CGPoint(x: 224, y: 250), CGPoint(x: 324, y: 250)],
        [CGPoint(x: 700, y: 250), CGPoint(x: 800, y: 250), CGPoint(x: 800, y: 350)],
        [CGPoint(x: 224, y: 674), CGPoint(x: 224, y: 774), CGPoint(x: 324, y: 774)],
        [CGPoint(x: 700, y: 774), CGPoint(x: 800, y: 774), CGPoint(x: 800, y: 674)]
    ] {
        ctx.move(to: points[0])
        for point in points.dropFirst() { ctx.addLine(to: point) }
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func png(size: Int, to url: URL) throws {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    ctx.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    draw(ctx)
    guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}
for size in [16, 32, 128, 256, 512] {
    try png(size: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(size: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try png(size: 1024, to: assets.appendingPathComponent("AppIcon.png"))
var box = CGRect(x: 0, y: 0, width: 1024, height: 1024)
guard let pdf = CGContext(assets.appendingPathComponent("AppIcon.pdf") as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
pdf.beginPDFPage(nil); draw(pdf); pdf.endPDFPage(); pdf.closePDF()
