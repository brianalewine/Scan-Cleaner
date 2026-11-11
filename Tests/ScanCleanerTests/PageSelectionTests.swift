import XCTest
@testable import ScanCleaner

final class PageSelectionTests: XCTestCase {
    @MainActor func testNoncontiguousMovePreservesOrderSelectionAndSavedOrder() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = Library(root: root)
        let pages = (0..<6).map { ScanPage(name: "\($0)", storedFile: "\($0).png") }
        library.state.pages = pages
        library.select(pages[1].id)
        library.selectPages([pages[1].id, pages[3].id])
        library.movePages(from: IndexSet([1, 3]), to: 6)
        XCTAssertEqual(library.state.pages.map(\.name), ["0", "2", "4", "5", "1", "3"])
        XCTAssertEqual(library.selectedPageIDs, [pages[1].id, pages[3].id])
        XCTAssertEqual(library.state.selection, pages[1].id)
        XCTAssertEqual(Library(root: root).state.pages.map(\.id), library.state.pages.map(\.id))
    }

    @MainActor func testRangeMoveUpAndSingleSelectionRestoresEditing() {
        let library = Library(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let pages = (0..<5).map { ScanPage(name: "\($0)", storedFile: "\($0).png") }
        library.state.pages = pages
        library.select(pages[2].id)
        library.selectPages(Set(pages[2...4].map(\.id)))
        XCTAssertTrue(library.hasMultipleSelection)
        var edits = library.edits
        edits.angle = 3
        library.edit(edits)
        library.markNext()
        library.deletePage()
        XCTAssertEqual(library.state.pages.count, 5)
        XCTAssertFalse(library.state.pages[2].reviewed)
        XCTAssertEqual(library.edits.angle, 0)
        library.movePages(from: IndexSet(2...4), to: 0)
        XCTAssertEqual(library.state.pages.map(\.name), ["2", "3", "4", "0", "1"])
        library.select(pages[3].id)
        XCTAssertFalse(library.hasMultipleSelection)
        XCTAssertEqual(library.selectedPageIDs, [pages[3].id])
        library.edit(edits)
        XCTAssertEqual(library.edits.angle, 3)
    }
}
