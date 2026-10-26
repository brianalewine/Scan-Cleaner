import CoreGraphics
import Foundation

enum PageBoundaryDetector {
    struct Edges {
        var left: Double?
        var right: Double?
        var top: Double?
        var bottom: Double?
        var found: Bool { left != nil || right != nil || top != nil || bottom != nil }
    }

    static func detect(_ image: CGImage) -> Edges {
        let scale = min(1, 1400 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard width >= 100, height >= 100 else { return Edges() }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let valid = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard valid else { return Edges() }

        func boundary(horizontal: Bool, reversed: Bool) -> Double? {
            let axis = horizontal ? width : height
            let across = horizontal ? height : width
            let radius = max(2, axis / 350)
            let samples = 48
            // Precompute gradients. Each profile runs from the page interior
            // toward the outside, independently of which edge is being tested.
            var gradients = [Double](repeating: 0, count: samples * axis)
            for row in 0..<samples {
                let cross = Int(Double(across - 1) * (0.1 + 0.8 * Double(row) / Double(samples - 1)))
                func pixel(_ position: Int) -> Double {
                    let p = reversed ? axis - 1 - position : position
                    return Double(pixels[horizontal ? cross * width + p : p * width + cross])
                }
                for position in radius..<(axis - radius) {
                    var inside = 0.0; var outside = 0.0
                    for offset in 1...radius {
                        inside += pixel(position - offset)
                        outside += pixel(position + offset)
                    }
                    let difference = (inside - outside) / Double(radius)
                    var broad = 0.0
                    for offset in (radius * 2)...(radius * 4) {
                        broad += pixel(max(0, position - offset)) - pixel(min(axis - 1, position + offset))
                    }
                    broad /= Double(radius * 2 + 1)
                    // A printed rule or thin stroke returns to the same paper
                    // brightness on both sides. A page edge separates regions.
                    if abs(broad) >= 3 && broad * difference > 0 {
                        gradients[row * axis + position] = difference
                    }
                }
            }
            struct Candidate { var position: Double; var slope: Double; var score: Double }
            var candidates: [Candidate] = []
            let slopeStep = max(2, axis / 200)
            for slope in stride(from: -axis * 15 / 100, through: axis * 15 / 100, by: slopeStep) {
                for middle in Int(Double(axis) * 0.72)..<(axis - radius - 1) {
                    var positive = 0; var negative = 0
                    var positiveScore = 0.0; var negativeScore = 0.0
                    var sections = [Int](repeating: 0, count: 6)
                    var reverseSections = sections
                    for row in 0..<samples {
                        let t = 0.1 + 0.8 * Double(row) / Double(samples - 1)
                        let position = middle + Int((t - 0.5) * Double(slope))
                        guard position >= radius, position < axis - radius else { continue }
                        let difference = gradients[row * axis + position]
                        if difference > 4 {
                            positive += 1; sections[row / 8] += 1
                            positiveScore += min(30, difference)
                        } else if difference < -4 {
                            negative += 1; reverseSections[row / 8] += 1
                            negativeScore += min(30, -difference)
                        }
                    }
                    // A real page boundary must persist through the page's
                    // height/width, rather than just following a few text lines.
                    let forward = positive >= 36 && sections.allSatisfy { $0 >= 4 }
                    let reverse = negative >= 36 && reverseSections.allSatisfy { $0 >= 4 }
                    let score = max(forward ? positiveScore : 0, reverse ? negativeScore : 0) / Double(samples)
                    if score >= 5 {
                        candidates.append(Candidate(position: Double(middle), slope: Double(slope), score: score))
                    }
                }
            }
            guard !candidates.isEmpty else { return nil }
            // Prefer the innermost sustained boundary, before the stack of
            // underlying sheets. Pick the strongest fit within that edge band.
            candidates.sort { $0.position < $1.position }
            let first = candidates[0].position
            let band = candidates.prefix { $0.position <= first + Double(radius * 3) }
            guard let best = band.max(by: { $0.score < $1.score }) else { return nil }
            let inset = best.position - abs(best.slope) * 0.5 - 1
            let edge = min(1, max(0, inset / Double(axis)))
            return reversed ? 1 - edge : edge
        }
        return Edges(left: boundary(horizontal: true, reversed: true),
                     right: boundary(horizontal: true, reversed: false),
                     top: boundary(horizontal: false, reversed: true),
                     bottom: boundary(horizontal: false, reversed: false))
    }
}
