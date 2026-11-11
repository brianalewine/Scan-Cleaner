import XCTest
@testable import ScanCleaner

final class AutoStraightenTests: XCTestCase {
    func testRotationCropCornersStayInsideSourceOnEverySide() throws {
        let image = try XCTUnwrap(CGContext(data: nil, width: 600, height: 900,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage())
        for turns in 0...3 {
            for angle in [-12.0, -3.0, 0.4, 6.0, 12.0] {
                var edits = PageEdits(); edits.angle = angle; edits.quarterTurns = turns
                let cropped = Imaging.cropRotationBorders(image, edits: edits)
                XCTAssertGreaterThan(cropped.left, 0)
                XCTAssertGreaterThan(cropped.right, 0)
                XCTAssertGreaterThan(cropped.top, 0)
                XCTAssertGreaterThan(cropped.bottom, 0)
                let transform = CGAffineTransform(rotationAngle: (angle + Double(turns) * 90) * .pi / 180)
                let bounds = CGRect(x: 0, y: 0, width: 600, height: 900).applying(transform).integral
                let r = cropped.cropRect
                let pixels = CGRect(x: r.minX * bounds.width, y: r.minY * bounds.height,
                                    width: r.width * bounds.width, height: r.height * bounds.height).integral
                for x in [pixels.minX, pixels.maxX] {
                    for y in [pixels.minY, pixels.maxY] {
                        let point = CGPoint(x: x + bounds.minX, y: y + bounds.minY).applying(transform.inverted())
                        XCTAssertTrue(point.x >= 0 && point.x <= 600 && point.y >= 0 && point.y <= 900)
                    }
                }
            }
        }
    }

    func testPortraitCropKeepsMaximumHeightWithoutExtraBuffer() throws {
        let image = try XCTUnwrap(CGContext(data: nil, width: 600, height: 900,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage())
        var edits = PageEdits(); edits.angle = 3
        let crop = Imaging.cropRotationBorders(image, edits: edits).cropRect
        let radians = edits.angle * .pi / 180
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 900)
            .applying(CGAffineTransform(rotationAngle: radians)).integral
        let expectedHeight = (900 * cos(radians) - 600 * sin(radians)) / cos(2 * radians)
        XCTAssertEqual(crop.height * bounds.height, expectedHeight, accuracy: 2)
    }

    @MainActor func testCurrentPageStraightensAndCropsAndCanBeUndone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: workspace.appendingPathComponent("TestScans/01-narratives.png"),
                                        to: root.appendingPathComponent("Originals/page.png"))
        var edits = PageEdits(); edits.angle = 4; edits.left = 0.12; edits.top = 0.03
        edits.spineSettings = SpineSettings(enabled: true, side: .right, width: 0.3, strength: 0.8)
        let first = ScanPage(name: "page.png", storedFile: "page.png", edits: edits)
        let second = ScanPage(name: "other.png", storedFile: "other.png", edits: edits)
        library.state = LibraryState(pages: [first, second], selection: first.id)
        library.straightenPage()
        XCTAssertTrue(library.busy)
        for _ in 0..<500 {
            if !library.busy { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(library.busy)
        XCTAssertNil(library.error)
        XCTAssertNotEqual(library.edits.angle, edits.angle)
        var expected = edits; expected.angle = library.edits.angle
        let source = try XCTUnwrap(Imaging.load(root.appendingPathComponent("Originals/page.png"), maxSize: 1400))
        expected = Imaging.cropRotationBorders(source, edits: expected)
        XCTAssertEqual(library.edits, expected)
        XCTAssertEqual(library.state.pages[1].edits, second.edits)
        XCTAssertEqual(library.state.pages[1].reviewed, second.reviewed)
        let saved = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
        XCTAssertEqual(saved.pages[0].edits, expected)
        library.undo()
        XCTAssertEqual(library.edits, edits)
    }
}
