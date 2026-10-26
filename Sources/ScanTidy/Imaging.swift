import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct AutoResult { var edits: PageEdits; var found: Bool }
enum Imaging {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static func load(_ url: URL, maxSize: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if let maxSize {
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSize, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        return context.createCGImage(image, from: image.extent)
    }
    static func rotated(_ image: CGImage, edits: PageEdits) -> CIImage {
        let input = CIImage(cgImage: image)
        let radians = (edits.angle + Double(edits.quarterTurns) * 90) * .pi / 180
        let transformed = input.transformed(by: CGAffineTransform(rotationAngle: radians))
        let bounds = transformed.extent.integral
        let moved = transformed.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let extent = CGRect(origin: .zero, size: bounds.size)
        return moved.composited(over: CIImage(color: CIColor.white).cropped(to: extent)).cropped(to: extent)
    }
    static let shadowKernel = CIColorKernel(source: """
    kernel vec4 liftSpine(__sample pixel, __sample light, float amount, float width, float reach, float side) {
        float x = destCoord().x / width;
        float distance = side < 0.0 ? min(x, 1.0-x) : (side < 0.5 ? x : 1.0-x);
        float edge = 1.0 - smoothstep(0.0, reach, distance);
        float luminance = dot(light.rgb, vec3(0.2126, 0.7152, 0.0722));
        float gain = clamp(0.96 / max(luminance, 0.25), 1.0, 3.0);
        vec3 result = min(pixel.rgb * mix(1.0, gain, amount * edge), vec3(1.0));
        return vec4(result, pixel.a);
    }
    """)
    static func render(_ image: CGImage, edits: PageEdits, crop: Bool) -> CGImage? {
        var output = rotated(image, edits: edits)
        let spine = edits.spineSettings
        if spine.enabled && spine.strength > 0, let kernel = shadowKernel {
            let blurred = output.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(12, output.extent.width * 0.025)]).cropped(to: output.extent)
            output = kernel.apply(extent: output.extent, arguments: [output, blurred, spine.strength, output.extent.width, max(0.01, min(1, spine.width)), edits.spine == nil ? -1.0 : (spine.side == .left ? 0.0 : 1.0)]) ?? output
        }
        if crop {
            let r = edits.cropRect
            let b = output.extent
            output = output.cropped(to: CGRect(x: r.minX*b.width, y: r.minY*b.height, width: r.width*b.width, height: r.height*b.height).integral.intersection(b))
        }
        return context.createCGImage(output, from: output.extent)
    }
    // Score text-line alignment on a small grayscale image, independent of page borders.
    static func textAngle(_ image: CGImage) -> Double {
        let width = min(1000, image.width)
        let height = Int(Double(image.height) * Double(width) / Double(image.width))
        var data = [UInt8](repeating: 255, count: width * height)
        let ok = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return 0 }
        var points: [(Double, Double)] = []
        for y in Int(Double(height)*0.08)..<Int(Double(height)*0.92) {
            for x in Int(Double(width)*0.14)..<Int(Double(width)*0.88) where data[y*width+x] < 145 {
                points.append((Double(x-width/2), Double(y)))
            }
        }
        guard points.count > 500 else { return 0 }
        func score(_ angle: Double) -> Double {
            let slope = tan(angle * .pi / 180)
            var rows = [Double](repeating: 0, count: height+200)
            for (x,y) in points {
                let row = y + x*slope + 100
                let i = Int(row); let f = row-Double(i)
                if i >= 0 && i+1 < rows.count { rows[i] += 1-f; rows[i+1] += f }
            }
            return rows.reduce(0) { $0 + $1*$1 }
        }
        var best = 0.0; var bestScore = score(0)
        for step in -60...60 {
            let angle = Double(step)*0.1; let candidate = score(angle)
            if candidate > bestScore { bestScore = candidate; best = angle }
        }
        let coarse = best
        for step in -5...5 {
            let angle = coarse+Double(step)*0.02; let candidate = score(angle)
            if candidate > bestScore { bestScore = candidate; best = angle }
        }
        // Bitmap rows run downwards, while Core Image rotation runs upwards.
        return -best
    }
    static func autoCrop(_ image: CGImage, edits: PageEdits) -> AutoResult {
        var thumbnail = [UInt8](repeating: 255, count: 32 * 32)
        let sampled = thumbnail.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        guard sampled, Int(thumbnail.max() ?? 0) - Int(thumbnail.min() ?? 0) > 12 else { return AutoResult(edits: edits, found: false) }
        // Detect before shadow correction, in the same rotated coordinates used
        // by preview and export. Re-detection does not depend on a previous crop.
        let base = rotated(image, edits: edits)
        guard let cg = context.createCGImage(base, from: base.extent) else { return AutoResult(edits: edits, found: false) }
        let edges = PageBoundaryDetector.detect(cg)
        guard edges.found else { return AutoResult(edits: edits, found: false) }
        let left = edges.left ?? 0
        let right = edges.right ?? 1
        let top = edges.top ?? 0
        let bottom = edges.bottom ?? 1
        guard right-left >= 0.5, bottom-top >= 0.5 else { return AutoResult(edits: edits, found: false) }
        var result = edits
        result.setCrop(CGRect(x: left, y: 1-bottom, width: right-left, height: bottom-top))
        return AutoResult(edits: result, found: true)
    }
    static func autoAdjust(_ image: CGImage, edits: PageEdits) -> AutoResult {
        var clean = edits; clean.angle = 0
        let base = rotated(image, edits: clean)
        guard let cg = context.createCGImage(base, from: base.extent) else { return AutoResult(edits: edits, found: false) }
        clean.angle = textAngle(cg)
        return autoCrop(image, edits: clean)
    }
    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
