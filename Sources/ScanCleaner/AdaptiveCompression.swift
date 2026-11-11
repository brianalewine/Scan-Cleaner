import Accelerate
import CoreGraphics
import Foundation

struct AdaptivePageLayers {
    let packed: Data
    let background: CGImage
    /// Integral pixel coordinates, with the origin at the top left as in CGImage.cropping(to:).
    let photoRects: [CGRect]
}

enum AdaptiveCompression {
    /// Keeps ambiguous areas as pictures. Returning nil asks the exporter to encode the whole page as a picture.
    static func separate(_ image: CGImage) throws -> AdaptivePageLayers? {
        try Task.checkCancellation()
        // Use display-referred gray samples for locating the paper and the antialiased edges of ink.
        guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let gray = CGContext(data: nil, width: image.width, height: image.height,
                                   bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let pixels = gray.data else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        gray.setFillColor(gray: 1, alpha: 1)
        gray.fill(bounds)
        gray.draw(image, in: bounds)
        var raster = vImage_Buffer(data: pixels, height: UInt(image.height), width: UInt(image.width), rowBytes: gray.bytesPerRow)
        var counts = [UInt](repeating: 0, count: 256)
        guard vImageHistogramCalculation_Planar8(&raster, &counts, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        var brighter: UInt = 0
        let brightFraction = UInt(image.width * image.height) / 5
        let paper = (0...255).reversed().first { tone in
            brighter += counts[tone]
            return brighter > brightFraction
        } ?? 255
        // A page without a light paper background is a poor candidate for ink/paper separation.
        guard paper >= 222 else { return nil }
        let isGray = image.colorSpace?.model == .monochrome
        guard let thumbnail = colorThumbnail(image) else { return nil }
        let color: CGContext? = isGray ? nil : thumbnail
        // Keep a nearly invisible photograph or pencil-only page in its original tonal range.
        if counts[0..<106].reduce(0, +) < 4 && counts[0..<max(1, paper - 4)].reduce(0, +) > 4 { return nil }

        // Keep tiles aligned with packed bytes and JPEG block boundaries. Bound the number
        // of tiles on large scans while retaining small annotations on short pages.
        let tile = max(16, ((max(image.width, image.height) / 64 + 7) / 8) * 8)
        let columns = (image.width + tile - 1) / tile
        let rows = (image.height + tile - 1) / tile
        var pictures = [Bool](repeating: false, count: columns * rows)
        var hasDetail = [Bool](repeating: false, count: columns * rows)
        let paperFloor = paper >= 253 ? paper - 6 : max(204, paper - 21)
        for row in 0..<rows {
            try Task.checkCancellation()
            for col in 0..<columns {
                let x = col * tile, y = row * tile
                let width = min(tile, image.width - x), height = min(tile, image.height - y)
                var block = vImage_Buffer(data: pixels.advanced(by: y * gray.bytesPerRow + x),
                                          height: UInt(height), width: UInt(width), rowBytes: gray.bytesPerRow)
                guard vImageHistogramCalculation_Planar8(&block, &counts, vImage_Flags(kvImageDoNotTile)) == kvImageNoError else { return nil }
                let ink = counts[0..<106].reduce(0, +)
                let tones = counts[106..<paperFloor].reduce(0, +)
                let area = UInt(width * height)
                // Antialiased black letters have midtone edges next to solid ink. Sparse
                // gray marks with no ink core, gray fills, and dense image areas stay continuous-tone.
                let hasTones = tones > max(2, area / 800) &&
                    (ink == 0 || containsShading(block, paperFloor: paperFloor, tile: tile))
                let dense = (ink + tones) * 5 > area * 3
                let rect = CGRect(x: x, y: y, width: width, height: height)
                pictures[row * columns + col] = hasTones || dense || hasColor(in: rect, thumbnail: color, page: bounds)
                hasDetail[row * columns + col] = ink + tones > max(2, area / 256)
            }
        }

        // The edge of a photograph may be a narrow strip of dark pixels against paper.
        // Retain detail bordering a solid group of picture tiles so that shadows and
        // the tips of illustrated objects aren't thresholded into black rectangles.
        var retained = pictures
        if rows >= 2 && columns >= 2 {
            for row in 0..<(rows - 1) {
                for col in 0..<(columns - 1) {
                    let i = row * columns + col
                    guard pictures[i], pictures[i + 1], pictures[i + columns], pictures[i + columns + 1] else { continue }
                    for y in max(0, row - 1)...min(rows - 1, row + 2) {
                        for x in max(0, col - 1)...min(columns - 1, col + 2) where hasDetail[y * columns + x] {
                            retained[y * columns + x] = true
                        }
                    }
                }
            }
        }
        let rects = pictureRectangles(retained, columns: columns, rows: rows, tile: tile, bounds: bounds)
        let pictureArea = rects.reduce(0) { $0 + $1.width * $1.height }
        guard rects.count <= 160, pictureArea <= 0.75 * bounds.width * bounds.height else { return nil }
        try Task.checkCancellation()
        // Split every pixel into a continuous-tone base and a four-bit brightness
        // multiplier. Picture tiles guide the split continuously across their edges.
        // The PDF paints both layers over the whole page, including across letters.
        let format = isGray ? CGImageAlphaInfo.none.rawValue : CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let base = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: isGray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: format), let memory = base.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        base.draw(image, in: bounds)
        let channels = isGray ? 1 : 4
        let stride = (image.width + 1) / 2
        var packed = Data(count: stride * image.height)
        let horizontal = (0..<image.width).map { coordinate($0, tile: tile, count: columns) }
        try packed.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            let output = bytes.bindMemory(to: UInt8.self)
            for y in 0..<image.height {
                if y.isMultiple(of: 64) { try Task.checkCancellation() }
                let (top, bottom, fy) = coordinate(y, tile: tile, count: rows)
                let row = memory.advanced(by: y * base.bytesPerRow)
                for x in 0..<image.width {
                    let (left, right, fx) = horizontal[x]
                    let upper = (retained[top * columns + left] ? 0 : 1 - fx) + (retained[top * columns + right] ? 0 : fx)
                    let lower = (retained[bottom * columns + left] ? 0 : 1 - fx) + (retained[bottom * columns + right] ? 0 : fx)
                    let weight = upper + (lower - upper) * fy
                    let pixel = row.advanced(by: x * channels)
                    let peak = isGray ? pixel[0] : max(pixel[0], pixel[1], pixel[2])
                    // Leave paper shading and scanner grain in the continuous-tone base.
                    let darkness = Double(max(0, paper - Int(peak)))
                    let inkWeight = min(1, max(0, (darkness - 24) / 32))
                    let density = weight * inkWeight * darkness / Double(paper)
                    let factor = 1 - density
                    let shade = UInt8((15 * factor).rounded())
                    let index = y * stride + x / 2
                    if x.isMultiple(of: 2) { output[index] = shade << 4 } else { output[index] |= shade }
                    if density > 0 {
                        for c in 0..<(isGray ? 1 : 3) {
                            pixel[c] = factor > 0 ? UInt8(clamping: Int((Double(pixel[c]) / factor).rounded())) : UInt8(paper)
                        }
                    }
                }
            }
        }
        guard let background = base.makeImage() else { return nil }
        return AdaptivePageLayers(packed: packed, background: background, photoRects: rects)
    }

    private static func coordinate(_ pixel: Int, tile: Int, count: Int) -> (Int, Int, Double) {
        let location = min(Double(count - 1), max(0, (Double(pixel) + 0.5) / Double(tile) - 0.5))
        let first = Int(location)
        return (first, min(first + 1, count - 1), location - Double(first))
    }

    private static func containsShading(_ block: vImage_Buffer, paperFloor: Int, tile: Int) -> Bool {
        let width = Int(block.width), height = Int(block.height), rowBytes = block.rowBytes
        let base = block.data.assumingMemoryBound(to: UInt8.self)
        let step = max(1, tile / 40)
        let radius = max(2, min(5, tile / 28))
        let allowance = max(2, width * height / (step * step * 140))
        var isolated = 0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let sample = base[y * rowBytes + x]
                guard sample >= 106 && sample < paperFloor else { continue }
                // An antialiased stroke has a black core within a few native pixels.
                // Pencil, shading, and other gray details can be far from any such core.
                var touchesInk = false
                for yy in max(0, y - radius)...min(height - 1, y + radius) {
                    let row = base.advanced(by: yy * rowBytes)
                    for xx in max(0, x - radius)...min(width - 1, x + radius) where row[xx] < 106 {
                        touchesInk = true
                        break
                    }
                    if touchesInk { break }
                }
                if !touchesInk {
                    isolated += 1
                    if isolated > allowance { return true }
                }
            }
        }
        return false
    }

    private static func colorThumbnail(_ image: CGImage) -> CGContext? {
        let scale = min(1, 1200 / Double(max(image.width, image.height)))
        let width = max(1, Int(ceil(Double(image.width) * scale)))
        let height = max(1, Int(ceil(Double(image.height) * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        return context
    }

    private static func hasColor(in rect: CGRect, thumbnail: CGContext?, page: CGRect) -> Bool {
        guard let thumbnail, let base = thumbnail.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        let scaleX = CGFloat(thumbnail.width) / page.width, scaleY = CGFloat(thumbnail.height) / page.height
        let left = Int(floor(rect.minX * scaleX)), top = Int(floor(rect.minY * scaleY))
        let right = min(thumbnail.width, Int(ceil(rect.maxX * scaleX)))
        let bottom = min(thumbnail.height, Int(ceil(rect.maxY * scaleY)))
        // Averaging before measuring chroma reduces colored scanner fringes around black ink.
        // One saturated sample can represent a tiny colored mark; a broad pale tint also matters.
        var tinted = 0, strong = 0
        for y in top..<bottom {
            let row = base.advanced(by: y * thumbnail.bytesPerRow)
            for x in left..<right {
                let p = row.advanced(by: x * 4)
                let chroma = max(p[0], p[1], p[2]) - min(p[0], p[1], p[2])
                if chroma >= 70 { return true }
                if chroma >= 32 { strong += 1 }
                if chroma >= 16 { tinted += 1 }
            }
        }
        let count = (right - left) * (bottom - top)
        return strong * 80 > count || tinted * 6 > count
    }

    /// Join similar horizontal runs on successive rows. This avoids a single bounding
    /// box around a page when retained regions follow a narrow border or form an L.
    private static func pictureRectangles(_ tiles: [Bool], columns: Int, rows: Int, tile: Int, bounds: CGRect) -> [CGRect] {
        var finished: [CGRect] = []
        var active: [CGRect] = []
        for y in 0..<rows {
            var next: [CGRect] = []
            var x = 0
            while x < columns {
                guard tiles[y * columns + x] else { x += 1; continue }
                let start = x
                repeat { x += 1 } while x < columns && tiles[y * columns + x]
                var run = CGRect(x: start * tile, y: y * tile, width: (x - start) * tile, height: tile).intersection(bounds)
                if let index = active.firstIndex(where: {
                    $0.minX < run.maxX && $0.maxX > run.minX &&
                        abs($0.minX - run.minX) <= CGFloat(tile) && abs($0.maxX - run.maxX) <= CGFloat(tile)
                }) {
                    run = run.union(active.remove(at: index))
                }
                next.append(run)
            }
            finished.append(contentsOf: active)
            active = next
        }
        return finished + active
    }
}
