import Foundation
import CoreGraphics

// Crop coordinates here use the canvas's top-left origin. The view converts to
// Core Image's bottom-left origin only when committing the finished gesture.
struct CropDrag {
    let start: CGPoint
    let crop: CGRect
    let size: CGSize
    let left: Bool
    let right: Bool
    let top: Bool
    let bottom: Bool
    var isResizing: Bool { left || right || top || bottom }

    init(start: CGPoint, crop: CGRect, size: CGSize) {
        self.start = start; self.crop = crop; self.size = size
        let rect = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                          width: crop.width * size.width, height: crop.height * size.height)
        let withinY = (rect.minY - 10...rect.maxY + 10).contains(start.y)
        let withinX = (rect.minX - 10...rect.maxX + 10).contains(start.x)
        left = withinY && abs(start.x - rect.minX) <= 10
        right = withinY && !left && abs(start.x - rect.maxX) <= 10
        top = withinX && abs(start.y - rect.minY) <= 10
        bottom = withinX && !top && abs(start.y - rect.maxY) <= 10
    }

    func updated(translation: CGSize) -> CGRect {
        let dx = translation.width / size.width
        let dy = translation.height / size.height
        guard isResizing else { return crop }
        // Keep the opposite edges fixed and prevent crossing or leaving the scan.
        let minimum: CGFloat = 0.050001
        let x1 = left ? max(0, min(crop.maxX - minimum, crop.minX + dx)) : crop.minX
        let x2 = right ? min(1, max(crop.minX + minimum, crop.maxX + dx)) : crop.maxX
        let y1 = top ? max(0, min(crop.maxY - minimum, crop.minY + dy)) : crop.minY
        let y2 = bottom ? min(1, max(crop.minY + minimum, crop.maxY + dy)) : crop.maxY
        return CGRect(x: x1, y: y1, width: x2-x1, height: y2-y1)
    }
}
