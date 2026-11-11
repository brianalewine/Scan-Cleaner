import XCTest
@testable import ScanCleaner

final class CropDragTests: XCTestCase {
    let size = CGSize(width: 600, height: 800)
    let crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

    func testDraggingEachEdgeKeepsOppositeEdgeFixed() {
        for (start, translation, expected) in [
            (CGPoint(x: 64, y: 400), CGSize(width: 60, height: 80), CGRect(x: 0.2, y: 0.1, width: 0.7, height: 0.8)),
            (CGPoint(x: 536, y: 400), CGSize(width: -60, height: 80), CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.8)),
            (CGPoint(x: 300, y: 84), CGSize(width: 60, height: 80), CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.7)),
            (CGPoint(x: 300, y: 716), CGSize(width: 60, height: -80), CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.7))
        ] {
            assertRect(CropDrag(start: start, crop: crop, size: size).updated(translation: translation), expected)
        }
    }

    func testCornerDragClampsAndCannotCrossOppositeCorner() {
        let drag = CropDrag(start: CGPoint(x: 60, y: 80), crop: crop, size: size)
        assertRect(drag.updated(translation: CGSize(width: -1000, height: -1000)), CGRect(x: 0, y: 0, width: 0.9, height: 0.9))
        let collapsed = drag.updated(translation: CGSize(width: 1000, height: 1000))
        XCTAssertGreaterThanOrEqual(collapsed.width, 0.05)
        XCTAssertGreaterThanOrEqual(collapsed.height, 0.05)
        XCTAssertEqual(collapsed.maxX, 0.9, accuracy: 0.00001)
        XCTAssertEqual(collapsed.maxY, 0.9, accuracy: 0.00001)
        var edits = PageEdits()
        edits.setCrop(CGRect(x: collapsed.minX, y: 1-collapsed.maxY, width: collapsed.width, height: collapsed.height))
        XCTAssertEqual(edits.left, collapsed.minX, accuracy: 0.00001)
    }

    func testDraggingAwayFromEdgesLeavesCropUnchanged() {
        let drag = CropDrag(start: CGPoint(x: 300, y: 400), crop: crop, size: size)
        XCTAssertFalse(drag.isResizing)
        assertRect(drag.updated(translation: CGSize(width: -180, height: -240)), crop)
        assertRect(drag.updated(translation: CGSize(width: 1000, height: 1000)), crop)
    }

    func assertRect(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.00001, file: file, line: line)
    }
}
