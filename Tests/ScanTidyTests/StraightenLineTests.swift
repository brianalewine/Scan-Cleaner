import XCTest
import CoreImage
@testable import ScanTidy

final class StraightenLineTests: XCTestCase {
    func testCorrectionUsesDisplayCoordinatesAndIsDirectionIndependent() throws {
        let a = CGPoint(x: 100, y: 100)
        let b = CGPoint(x: 500, y: 120)
        let correction = try XCTUnwrap(StraightenLine.correction(from: a, to: b))
        XCTAssertEqual(correction, 2.862405, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(StraightenLine.correction(from: b, to: a)), correction, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(StraightenLine.correction(from: a, to: CGPoint(x: 500, y: 80))), -correction, accuracy: 0.00001)
        XCTAssertNil(StraightenLine.correction(from: a, to: a))
    }

    @MainActor func testLineAddsToExistingRotationAndPreservesOtherEditsAndUndo() {
        let library = Library(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var edits = PageEdits(); edits.angle = -1; edits.quarterTurns = 1; edits.left = 0.1
        edits.spineSettings = SpineSettings(enabled: true, side: .right)
        let page = ScanPage(name: "test.png", storedFile: "test.png", edits: edits)
        library.state = LibraryState(pages: [page], selection: page.id)
        library.drawingStraightenLine = true
        XCTAssertTrue(library.straightenLine(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 120)))
        XCTAssertEqual(library.edits.angle, 1.862405, accuracy: 0.00001)
        XCTAssertEqual(library.edits.quarterTurns, 1)
        XCTAssertEqual(library.edits.left, 0.1)
        XCTAssertEqual(library.edits.spineSettings, edits.spineSettings)
        XCTAssertFalse(library.drawingStraightenLine)
        library.undo()
        XCTAssertEqual(library.edits, edits)
        library.drawingStraightenLine = true
        library.cancelStraightenLine()
        XCTAssertEqual(library.edits, edits)
        XCTAssertFalse(library.drawingStraightenLine)
        library.resetPage()
        XCTAssertEqual(library.edits, PageEdits())
        library.undo()
        XCTAssertEqual(library.edits, edits)
    }

    @MainActor func testTooShortOrSteepLineDoesNotChangeEdits() {
        let library = Library(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let page = ScanPage(name: "test.png", storedFile: "test.png")
        library.state = LibraryState(pages: [page], selection: page.id)
        let before = library.edits
        XCTAssertFalse(library.straightenLine(from: .zero, to: CGPoint(x: 1, y: 1)))
        XCTAssertFalse(library.straightenLine(from: .zero, to: CGPoint(x: 100, y: 100)))
        XCTAssertEqual(library.edits, before)
    }
}
