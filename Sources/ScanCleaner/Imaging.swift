import AppKit
import CoreImage
import ImageIO
import Vision
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
    // Find the largest axis-aligned rectangle inside the rotated source.
    // Width and height shrink independently; keeping the canvas aspect ratio
    // unnecessarily removes extra page content from the shorter crop edges.
    static func cropRotationBorders(_ image: CGImage, edits: PageEdits) -> PageEdits {
        let radians = (edits.angle + Double(edits.quarterTurns) * 90) * .pi / 180
        let c = abs(cos(radians)), s = abs(sin(radians))
        guard min(c, s) > 0.000001 else { return edits }
        let width = Double(image.width), height = Double(image.height)
        let transform = CGAffineTransform(rotationAngle: radians)
        let sourceBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let bounds = sourceBounds.applying(transform).integral
        // Candidate maxima on each source-edge constraint, plus their intersection.
        var candidates: [CGSize] = [
            CGSize(width: width / (2 * c), height: width / (2 * s)),
            CGSize(width: height / (2 * s), height: height / (2 * c))
        ]
        let determinant = c * c - s * s
        if abs(determinant) > 0.000001 {
            candidates.append(CGSize(width: (width * c - height * s) / determinant,
                                     height: (height * c - width * s) / determinant))
        }
        guard let size = candidates.filter({
            $0.width > 0 && $0.height > 0 &&
            c * $0.width + s * $0.height <= width + 0.000001 &&
            s * $0.width + c * $0.height <= height + 0.000001
        }).max(by: { $0.width * $0.height < $1.width * $1.height }) else { return edits }
        let center = CGPoint(x: width / 2, y: height / 2).applying(transform)
        // Round inward once, with no additional crop buffer.
        let left = ceil(center.x - bounds.minX - size.width / 2) + 0.000001
        let bottom = ceil(center.y - bounds.minY - size.height / 2) + 0.000001
        let right = floor(center.x - bounds.minX + size.width / 2) - 0.000001
        let top = floor(center.y - bounds.minY + size.height / 2) - 0.000001
        let safe = CGRect(x: left / bounds.width, y: bottom / bounds.height,
                          width: (right - left) / bounds.width,
                          height: (top - bottom) / bounds.height)
        var result = edits
        result.setCrop(edits.cropRect.intersection(safe))
        return result
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
    static func sideEdges(_ image: CGImage) -> (left: Double?, right: Double?) {
        let width = min(1000, image.width)
        let height = Int(Double(image.height) * Double(width) / Double(image.width))
        guard width >= 100, height >= 100 else { return (nil, nil) }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return (nil, nil) }
        let radius = max(2, width / 250)
        func edge(right: Bool) -> Double? {
            for distance in Int(Double(width) * 0.80)..<(width - radius * 2) {
                let x = right ? distance : width - 1 - distance
                var differences: [Double] = []
                for y in stride(from: height / 8, to: height * 7 / 8, by: max(1, height / 100)) {
                    var inner = 0.0; var outer = 0.0
                    for step in 1...radius {
                        inner += Double(pixels[y * width + x + (right ? -step : step)])
                        outer += Double(pixels[y * width + x + (right ? step : -step)])
                    }
                    differences.append((inner - outer) / Double(radius))
                }
                differences.sort()
                if differences[differences.count * 3 / 10] > 6 {
                    return Double(right ? x - radius : x + radius) / Double(width)
                }
            }
            return nil
        }
        return (edge(right: false), edge(right: true))
    }
    static func autoCrop(_ image: CGImage, edits: PageEdits) -> AutoResult {
        var thumbnail = [UInt8](repeating: 255, count: 32 * 32)
        let sampled = thumbnail.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        guard sampled, Int(thumbnail.max() ?? 0) - Int(thumbnail.min() ?? 0) > 12 else { return AutoResult(edits: cropRotationBorders(image, edits: edits), found: false) }
        let base = rotated(image, edits: edits)
        guard let cg = context.createCGImage(base, from: base.extent) else { return AutoResult(edits: cropRotationBorders(image, edits: edits), found: false) }
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 12
        request.minimumConfidence = 0.5
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1
        request.minimumSize = 0.35
        request.quadratureTolerance = 20
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        let rectangles = (request.results ?? []).filter {
            let b = $0.boundingBox
            return b.width * b.height > 0.45 && b.contains(CGPoint(x: 0.5, y: 0.5))
        }
        var crop = edits.cropRect
        var found = false
        if let rect = rectangles.max(by: { $0.confidence < $1.confidence }) {
            let xs = [rect.topLeft.x, rect.topRight.x, rect.bottomLeft.x, rect.bottomRight.x].sorted()
            let ys = [rect.topLeft.y, rect.topRight.y, rect.bottomLeft.y, rect.bottomRight.y].sorted()
            crop = CGRect(x: xs[1], y: ys[1], width: xs[2] - xs[1], height: ys[2] - ys[1])
            found = true
        }
        let edges = sideEdges(cg)
        let left = max(crop.minX, edges.left ?? crop.minX)
        let right = min(crop.maxX, edges.right ?? crop.maxX)
        found = found || edges.left != nil || edges.right != nil
        guard found, right - left >= 0.5, crop.height >= 0.5 else { return AutoResult(edits: cropRotationBorders(image, edits: edits), found: false) }
        var result = edits
        result.setCrop(CGRect(x: left, y: crop.minY, width: right-left, height: crop.height))
        return AutoResult(edits: cropRotationBorders(image, edits: result), found: true)
    }
    static func autoAdjust(_ image: CGImage, edits: PageEdits) -> AutoResult {
        var clean = edits; clean.angle = 0
        let base = rotated(image, edits: clean)
        guard let cg = context.createCGImage(base, from: base.extent) else { return AutoResult(edits: clean, found: false) }
        clean.angle = textAngle(cg)
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 6
        request.minimumConfidence = 0.5
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1
        request.minimumSize = 0.35
        request.quadratureTolerance = 20
        do { try VNImageRequestHandler(cgImage: cg).perform([request]) } catch { return AutoResult(edits: clean, found: false) }
        guard let rect = request.results?.filter({ $0.boundingBox.width * $0.boundingBox.height > 0.25 }).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else { return AutoResult(edits: clean, found: false) }
        let dx = (rect.topRight.x-rect.topLeft.x) * CGFloat(cg.width)
        let dy = (rect.topRight.y-rect.topLeft.y) * CGFloat(cg.height)
        let angle = -atan2(dy, dx) * 180 / .pi
        guard abs(angle) <= 12 else { return AutoResult(edits: clean, found: false) }
        clean.angle = angle
        let transform = CGAffineTransform(rotationAngle: angle * .pi / 180)
        let bounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height).applying(transform).integral
        let points = [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight].map { p -> CGPoint in
            let v = CGPoint(x: p.x * CGFloat(cg.width), y: p.y * CGFloat(cg.height)).applying(transform)
            return CGPoint(x: (v.x-bounds.minX)/bounds.width, y: (v.y-bounds.minY)/bounds.height)
        }
        let xs = points.map(\.x).sorted(); let ys = points.map(\.y).sorted()
        clean.setCrop(CGRect(x: xs[1], y: ys[1], width: xs[2]-xs[1], height: ys[2]-ys[1]))
        return AutoResult(edits: clean, found: true)
    }
    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
