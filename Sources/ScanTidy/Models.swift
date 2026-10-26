import Foundation
import CoreGraphics

enum SpineSide: String, Codable, CaseIterable { case left, right }
struct SpineSettings: Codable, Equatable {
    var enabled = false
    var side: SpineSide = .left
    var width = 0.25
    var strength = 0.65
}

struct PageEdits: Codable, Equatable {
    var angle = 0.0
    var left = 0.0
    var right = 0.0
    var top = 0.0
    var bottom = 0.0
    var shadow = 0.0 // Retained for libraries saved by version 1.0.
    var spine: SpineSettings?
    var spineSettings: SpineSettings {
        get { spine ?? SpineSettings(enabled: shadow > 0, width: 0.33, strength: shadow > 0 ? shadow : 0.65) }
        set { spine = newValue; shadow = 0 }
    }
    var quarterTurns = 0
    var cropRect: CGRect { CGRect(x: left, y: bottom, width: max(0.05, 1 - left - right), height: max(0.05, 1 - top - bottom)) }
    mutating func setCrop(_ rect: CGRect) {
        let r = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, r.width >= 0.05, r.height >= 0.05 else { return }
        left = r.minX; right = 1-r.maxX; bottom = r.minY; top = 1-r.maxY
    }
}
struct ScanPage: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var storedFile: String
    var edits = PageEdits()
    var reviewed = false
    var hasBeenEdited: Bool?
    var isAdjusted: Bool { hasBeenEdited ?? (reviewed || edits != PageEdits()) }
}
struct LibraryState: Codable {
    var pages: [ScanPage] = []
    var selection: UUID?
    var spineDefaults: SpineSettings?
    var grid: Bool? = true
    var croppedPreview: Bool? = false
    var showOriginal: Bool? = false
}
