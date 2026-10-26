import Foundation
import CoreGraphics

enum StraightenLine {
    // Canvas Y points down; positive Core Image rotation turns counterclockwise.
    // Normalize the direction so clicking right-to-left gives the same result.
    static func correction(from start: CGPoint, to end: CGPoint) -> Double? {
        let dx = end.x - start.x; let dy = end.y - start.y
        guard dx.isFinite, dy.isFinite, hypot(dx, dy) >= 8 else { return nil }
        var angle = atan2(dy, dx) * 180 / .pi
        if angle > 90 { angle -= 180 }
        if angle < -90 { angle += 180 }
        return angle
    }
}
