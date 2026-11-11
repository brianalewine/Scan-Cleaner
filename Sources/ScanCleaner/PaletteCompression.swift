import CoreGraphics
import CoreImage
import Foundation

/// Index zero shows the photographic layer. All other samples select an ink or paper color.
enum PaletteCompression {
    struct Result {
        let layer: PDFImageLayer
        let background: CGImage?
    }

    private struct Swatch {
        let color: SIMD3<Int>
        let weight: Int
    }

    private struct Box {
        let samples: [Swatch]
        let axis: Int
        let priority: Double

        init(_ samples: [Swatch]) {
            self.samples = samples
            var lo = SIMD3<Int>(repeating: 255), hi = SIMD3<Int>(repeating: 0)
            var weight = 0
            for sample in samples {
                weight += sample.weight
                for i in 0..<3 {
                    lo[i] = min(lo[i], sample.color[i])
                    hi[i] = max(hi[i], sample.color[i])
                }
            }
            let range = hi &- lo
            axis = range.x >= max(range.y, range.z) ? 0 : (range.y >= range.z ? 1 : 2)
            priority = Double(range[axis]) * sqrt(Double(weight))
        }

        var average: SIMD3<Int> {
            var sum = SIMD3<Int>(repeating: 0), weight = 0
            for s in samples {
                sum = sum &+ (s.color &* s.weight)
                weight += s.weight
            }
            return sum / weight
        }
    }

    static func encode(_ image: CGImage, level: Int, opaque: Bool = false, colorLimit: Int? = nil) throws -> Result {
        let strength = min(5, max(1, level))
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let scan = CIImage(cgImage: image)
        let sharp = scan.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 1.0, kCIInputIntensityKey: 0.18 * Double(strength)
        ]).cropped(to: scan.extent)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue),
              let memory = context.data?.assumingMemoryBound(to: UInt8.self),
              let sharpened = Imaging.context.createCGImage(sharp, from: scan.extent) else {
            throw PDFExportError.message("Could not prepare the scan colors.")
        }
        context.draw(sharpened, in: bounds)
        if level == 10 && !opaque {
            guard let original = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue),
                  let source = original.data?.assumingMemoryBound(to: UInt8.self) else {
                throw PDFExportError.message("Could not prepare source ink colors.")
            }
            original.draw(image, in: bounds)
            for y in 0..<image.height {
                try Task.checkCancellation()
                let row = memory.advanced(by: y * context.bytesPerRow)
                let input = source.advanced(by: y * original.bytesPerRow)
                for x in 0..<image.width {
                    let p = input.advanced(by: x * 4)
                    if Int(max(p[0], p[1], p[2])) - Int(min(p[0], p[1], p[2])) >= 32 {
                        for c in 0..<3 { row[x * 4 + c] = p[c] }
                    }
                }
            }
        }
        let columns = (image.width + 7) / 8
        let rows = (image.height + 7) / 8
        var highlights = [Int](repeating: 0, count: opaque ? 0 : columns * rows)
        let separateReverseType = !opaque && level == 10
        var brightnessSums = [Int](repeating: 0, count: separateReverseType ? columns * rows : 0)
        func light(_ p: UnsafePointer<UInt8>) -> Int { (Int(p[0]) + 2 * Int(p[1]) + Int(p[2])) / 4 }
        var counts = [Int](repeating: 0, count: 32768)
        var sums = [SIMD3<Int>](repeating: .zero, count: counts.count)
        let shift = level == 10 && !opaque ? 3 : [3, 3, 4, 4, 5][strength - 1]
        func key(_ p: UnsafePointer<UInt8>) -> Int {
            (Int(p[0] >> shift) << 10) | (Int(p[1] >> shift) << 5) | Int(p[2] >> shift)
        }
        for y in 0..<image.height {
            try Task.checkCancellation()
            let row = memory.advanced(by: y * context.bytesPerRow)
            for x in 0..<image.width {
                let p = row.advanced(by: x * 4), k = key(p)
                let block = (y / 8) * columns + x / 8
                if separateReverseType { brightnessSums[block] += light(p) }
                else if !opaque { highlights[block] = max(highlights[block], light(p)) }
                counts[k] += 1
                sums[k] = sums[k] &+ SIMD3(Int(p[0]), Int(p[1]), Int(p[2]))
            }
        }
        let occupied = counts.indices.filter { counts[$0] > 0 }
        // Square-root weighting reserves colors for small headings alongside large paper regions.
        let samples = occupied.map { Swatch(color: sums[$0] / counts[$0], weight: max(1, Int(sqrt(Double(counts[$0]))))) }
        var boxes = [Box(samples)]
        let limit = colorLimit ?? [192, 128, 80, 48, 32, 16, 8, 4, 2, 1][min(10, max(1, level)) - 1]
        while boxes.count < limit, let index = boxes.indices.max(by: { boxes[$0].priority < boxes[$1].priority }),
              boxes[index].priority > 0 {
            let box = boxes.remove(at: index)
            let sorted = box.samples.sorted { $0.color[box.axis] < $1.color[box.axis] }
            let half = sorted.reduce(0) { $0 + $1.weight } / 2
            var cut = 0, weight = 0
            repeat { weight += sorted[cut].weight; cut += 1 } while weight < half && cut < sorted.count - 1
            boxes.append(Box(Array(sorted[..<cut])))
            boxes.append(Box(Array(sorted[cut...])))
        }
        var colors = boxes.map(\.average)
        if level > 5 && !opaque {
            // Keep a dark ink swatch even when broad areas of a photo dominate the palette.
            func brightness(_ c: SIMD3<Int>) -> Int { c.x + 2 * c.y + c.z }
            if let dark = samples.min(by: { brightness($0.color) < brightness($1.color) }),
               let index = colors.indices.min(by: { brightness(colors[$0]) < brightness(colors[$1]) }) {
                colors[index] = dark.color
            }
        }
        if level == 10 && !opaque {
            // Use populated source color bins, preserving their measured RGB values.
            // Only contrasting colored ink on light paper enters this layer below.
            let colored = occupied.filter {
                let c = sums[$0] / counts[$0]
                return max(c.x, c.y, c.z) - min(c.x, c.y, c.z) >= 32
                    && (c.x + 2 * c.y + c.z) / 4 < 180
            }.sorted { counts[$0] > counts[$1] }
            for bin in colored {
                let color = sums[bin] / counts[bin]
                if colors.allSatisfy({ existing in
                    max(abs(existing.x - color.x), abs(existing.y - color.y), abs(existing.z - color.z)) > 10
                }) {
                    colors.append(color)
                    if colors.count == 33 { break }
                }
            }
        }
        var lookup = [UInt8](repeating: 0, count: counts.count)
        for k in occupied {
            let sample = sums[k] / counts[k]
            var best = Int.max
            for (i, color) in colors.enumerated() {
                if level == 10 && !opaque && i > 0 && max(sample.x, sample.y, sample.z) - min(sample.x, sample.y, sample.z) < 32 { continue }
                let d = sample &- color
                let distance = d.x * d.x + d.y * d.y + d.z * d.z
                if distance < best { best = distance; lookup[k] = UInt8(i + 1) }
            }
        }
        if opaque {
            // PDF indexed images pack samples high bits first, padding each row independently.
            let bits: Int
            switch colors.count {
            case 1...2: bits = 1
            case 3...4: bits = 2
            case 5...16: bits = 4
            default: bits = 8
            }
            let rowBytes = (image.width * bits + 7) / 8
            var packed = Data(count: rowBytes * image.height)
            try packed.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                for y in 0..<image.height {
                    try Task.checkCancellation()
                    let row = memory.advanced(by: y * context.bytesPerRow)
                    for x in 0..<image.width {
                        let bit = x * bits
                        let index = lookup[key(row.advanced(by: x * 4))] - 1
                        out[y * rowBytes + bit / 8] |= index << (8 - bits - bit % 8)
                    }
                }
            }
            let layer = PDFImageLayer(rect: bounds, width: image.width, height: image.height,
                                      format: .indexed(colors.count - 1, table(colors), bits: bits, masked: false),
                                      filter: "/Filter /FlateDecode", data: try PDFImageEncoding.deflate(packed))
            return Result(layer: layer, background: nil)
        }
        var indices = Data(count: image.width * image.height)
        var needsBackground = false
        let tolerance = level > 5 ? 45 : 5 + 6 * strength
        // Estimate the surrounding light tone. Only high-contrast detail needs a
        // full-resolution sample; paper grain and broad gradients stay photographic.
        var localLight = highlights
        for by in 0..<rows {
            for bx in 0..<columns {
                if separateReverseType {
                    let x0 = max(0, bx - 2), x1 = min(columns - 1, bx + 2)
                    let y0 = max(0, by - 2), y1 = min(rows - 1, by + 2)
                    var sum = 0
                    for y in y0...y1 {
                        for x in x0...x1 { sum += brightnessSums[y * columns + x] }
                    }
                    let area = (min(image.width, (x1 + 1) * 8) - x0 * 8)
                        * (min(image.height, (y1 + 1) * 8) - y0 * 8)
                    localLight[by * columns + bx] = sum / area
                    continue
                }
                var peak = 0
                for yy in max(0, by - 1)...min(rows - 1, by + 1) {
                    for xx in max(0, bx - 1)...min(columns - 1, bx + 1) {
                        peak = max(peak, highlights[yy * columns + xx])
                    }
                }
                localLight[by * columns + bx] = peak
            }
        }
        // A bright letter on dark artwork can be the brightest pixel in several
        // neighboring tiles. Sample the surround at the pixel itself to distinguish
        // light lettering from dark ink on paper, without snapping to tile edges.
        // Interpolate the neighborhood means at their tile centers.
        func neighbors(_ position: Int, _ count: Int) -> (Int, Int, Int) {
            let centered = max(0, position - 4)
            let first = min(count - 1, centered / 8)
            return (first, min(first + 1, count - 1), centered % 8)
        }
        let horizontal = separateReverseType ? (0..<image.width).map { neighbors($0, columns) } : []
        let lightTypeIndex = UInt8(colors.count + 1)
        var hasLightType = false
        try indices.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            for y in 0..<image.height {
                try Task.checkCancellation()
                let row = memory.advanced(by: y * context.bytesPerRow)
                for x in 0..<image.width {
                    let p = row.advanced(by: x * 4)
                    let index = lookup[key(p)], color = colors[Int(index) - 1]
                    let error = max(abs(Int(p[0]) - color.x), abs(Int(p[1]) - color.y), abs(Int(p[2]) - color.z))
                    var paper = localLight[(y / 8) * columns + x / 8]
                    if separateReverseType {
                        let (left, right, dx) = horizontal[x]
                        let (top, bottom, dy) = neighbors(y, rows)
                        let upper = localLight[top * columns + left] * (8 - dx) + localLight[top * columns + right] * dx
                        let lower = localLight[bottom * columns + left] * (8 - dx) + localLight[bottom * columns + right] * dx
                        let surround = (upper * (8 - dy) + lower * dy) / 64
                        paper = surround < 120 ? 0 : min(255, surround + 45)
                        if surround < 120 && min(p[0], p[1], p[2]) >= 195 && light(p) - surround >= 95 {
                            out[y * image.width + x] = lightTypeIndex
                            hasLightType = true
                            continue
                        }
                    }
                    if separateReverseType {
                        let chroma = Int(max(p[0], p[1], p[2])) - Int(min(p[0], p[1], p[2]))
                        let colorChroma = max(color.x, color.y, color.z) - min(color.x, color.y, color.z)
                        let left = row.advanced(by: max(0, x - 6) * 4)
                        let right = row.advanced(by: min(image.width - 1, x + 6) * 4)
                        let top = memory.advanced(by: max(0, y - 6) * context.bytesPerRow + x * 4)
                        let bottom = memory.advanced(by: min(image.height - 1, y + 6) * context.bytesPerRow + x * 4)
                        var variation = 0
                        for c in 0..<3 {
                            variation = max(variation, abs(Int(left[c]) - Int(right[c])),
                                            abs(Int(top[c]) - Int(bottom[c])))
                        }
                        if (paper >= 210 || variation <= 12) && chroma >= 32 && colorChroma >= 32 && error <= 10 && light(p) < 180 {
                            out[y * image.width + x] = index
                            continue
                        }
                        // Colored samples that fail the ink check remain photographic.
                        if colorChroma >= 32 {
                            needsBackground = true
                            continue
                        }
                    }
                    let contrast = paper - light(p)
                    // At small palette sizes, retain the middle of a dark stroke even when
                    // the palette has no matching gray. Keep deep photographic shadows
                    // together in the background instead of painting these in flat ink.
                    let darkInk = level > 5 && max(color.x, color.y, color.z) < 80
                    let allowance = darkInk ? max(tolerance, min(125, contrast / 2)) : tolerance
                    if (!darkInk || paper >= 155) && contrast >= 24 + 5 * strength && error <= allowance {
                        out[y * image.width + x] = index
                    } else {
                        needsBackground = true
                    }
                }
            }
        }
        if separateReverseType && colors.count > 1 {
            // Photographic color samples add noise and cost bytes. Retain connected
            // colored ink patches only when they reach a light paper background.
            try indices.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                var visited = [Bool](repeating: false, count: image.width * image.height)
                var patch: [Int] = []
                for start in 0..<out.count {
                    if start.isMultiple(of: image.width * 64) { try Task.checkCancellation() }
                    let value = out[start]
                    guard value > 1, value < lightTypeIndex, !visited[start] else { continue }
                    patch.removeAll(keepingCapacity: true)
                    patch.append(start)
                    visited[start] = true
                    var cursor = 0
                    var paperSamples = 0
                    while cursor < patch.count {
                        let pixel = patch[cursor]
                        let x = pixel % image.width
                        let y = pixel / image.width
                        if localLight[(y / 8) * columns + x / 8] >= 180 { paperSamples += 1 }
                        let neighbors = [x > 0 ? pixel - 1 : pixel, x + 1 < image.width ? pixel + 1 : pixel,
                                         pixel >= image.width ? pixel - image.width : pixel,
                                         pixel + image.width < out.count ? pixel + image.width : pixel]
                        for neighbor in neighbors where !visited[neighbor] && out[neighbor] > 1 && out[neighbor] < lightTypeIndex {
                            let adjacent = colors[Int(out[neighbor]) - 1]
                            let current = colors[Int(out[pixel]) - 1]
                            guard max(abs(adjacent.x - current.x), abs(adjacent.y - current.y), abs(adjacent.z - current.z)) <= 32 else { continue }
                            visited[neighbor] = true
                            patch.append(neighbor)
                        }
                        cursor += 1
                    }
                    if paperSamples * 5 < patch.count {
                        for pixel in patch { out[pixel] = 0 }
                        needsBackground = true
                    } else {
                        var sum = SIMD3<Int>.zero
                        for pixel in patch { sum = sum &+ colors[Int(out[pixel]) - 1] }
                        let average = sum / patch.count
                        let representative = colors.indices.dropFirst().min { a, b in
                            let da = colors[a] &- average, db = colors[b] &- average
                            return da.x * da.x + da.y * da.y + da.z * da.z < db.x * db.x + db.y * db.y + db.z * db.z
                        }!
                        let ink = colors[representative]
                        for pixel in patch {
                            let sample = colors[Int(out[pixel]) - 1]
                            if max(abs(sample.x - ink.x), abs(sample.y - ink.y), abs(sample.z - ink.z)) <= 16 {
                                out[pixel] = UInt8(representative + 1)
                            }
                        }
                    }
                }
            }
        }
        if hasLightType { colors.append(SIMD3(repeating: 235)) }
        let used = Set(indices).subtracting([0]).sorted()
        var remap = [UInt8](repeating: 0, count: 256)
        for (index, value) in used.enumerated() { remap[Int(value)] = UInt8(index + 1) }
        let bits: Int
        switch used.count {
        case 0...1: bits = 1
        case 2...3: bits = 2
        case 4...15: bits = 4
        default: bits = 8
        }
        let rowBytes = (image.width * bits + 7) / 8
        var packed = Data(count: rowBytes * image.height)
        try packed.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            for y in 0..<image.height {
                try Task.checkCancellation()
                for x in 0..<image.width {
                    let bit = x * bits
                    output[y * rowBytes + bit / 8] |= remap[Int(indices[y * image.width + x])] << (8 - bits - bit % 8)
                }
            }
        }
        let palette = table([.zero] + used.map { colors[Int($0) - 1] })
        let layer = PDFImageLayer(rect: bounds, width: image.width, height: image.height, format: .indexed(used.count, palette, bits: bits),
                                  filter: "/Filter /FlateDecode", data: try PDFImageEncoding.deflate(packed))
        guard needsBackground else { return Result(layer: layer, background: nil) }
        context.draw(image, in: bounds)
        // Fill beneath foreground strokes from adjacent scan colors. This keeps a
        // second, blurred copy of the letters out of the downsampled background.
        try indices.withUnsafeBytes { (mask: UnsafeRawBufferPointer) in
            for y in 0..<image.height {
                try Task.checkCancellation()
                let row = memory.advanced(by: y * context.bytesPerRow)
                var x = 0
                while x < image.width {
                    guard mask[y * image.width + x] != 0 else { x += 1; continue }
                    let start = x
                    while x < image.width && mask[y * image.width + x] != 0 { x += 1 }
                    let left = start > 0 ? start - 1 : min(x, image.width - 1)
                    let right = x < image.width ? x : left
                    for c in 0..<3 {
                        let a = Int(row[left * 4 + c]), b = Int(row[right * 4 + c])
                        for i in start..<x {
                            row[i * 4 + c] = UInt8(a + (b - a) * (i - start + 1) / (x - start + 1))
                        }
                    }
                }
            }
        }
        guard let background = context.makeImage() else { throw PDFExportError.message("Could not prepare photographic detail.") }
        return Result(layer: layer, background: background)
    }

    private static func table(_ colors: [SIMD3<Int>]) -> String {
        colors.flatMap { [$0.x, $0.y, $0.z] }.map { String(format: "%02X", $0) }.joined()
    }
}
