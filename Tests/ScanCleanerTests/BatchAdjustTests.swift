import XCTest
@testable import ScanCleaner

final class BatchAdjustTests: XCTestCase {
    @MainActor func testStopBeforeProcessingLeavesPagesUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        library.state.pages = [ScanPage(name: "missing.png", storedFile: "missing.png")]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(library.state.pages)
        library.straightenAndCropAll()
        XCTAssertTrue(library.batchRunning)
        library.cancelCurrentOperation()
        for _ in 0..<100 {
            if !library.busy { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(library.busy)
        XCTAssertFalse(library.batchRunning)
        XCTAssertNil(library.error)
        XCTAssertTrue(library.status.hasPrefix("Stopped"))
        XCTAssertEqual(try encoder.encode(library.state.pages), before)
    }

    @MainActor func testStopDiscardsInFlightPageAndUndoRestoresCompletedPages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: workspace.appendingPathComponent("TestScans/01-narratives.png"),
                                        to: root.appendingPathComponent("Originals/page.png"))
        library.state.pages = (1...4).map { ScanPage(name: "page \($0)", storedFile: "page.png") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(library.state.pages)
        library.straightenAndCropAll()
        for _ in 0..<1000 {
            if library.state.pages[0].hasBeenEdited == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(library.batchRunning)
        let atStop = try encoder.encode(library.state.pages)
        library.stopStraightenAndCrop()
        for _ in 0..<1000 {
            if !library.busy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(library.busy)
        XCTAssertTrue(library.status.hasPrefix("Stopped"))
        XCTAssertEqual(try encoder.encode(library.state.pages), atStop)
        XCTAssertNotEqual(atStop, before)
        library.undo()
        XCTAssertEqual(try encoder.encode(library.state.pages), before)
        let saved = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
        XCTAssertEqual(try encoder.encode(saved.pages), before)
    }

    @MainActor func testBatchStraightensCropsAndOneUndoRestoresEveryPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: workspace.appendingPathComponent("TestScans/01-narratives.png"),
                                        to: root.appendingPathComponent("Originals/page.png"))
        var edits = PageEdits(); edits.angle = 4
        edits.spineSettings = SpineSettings(enabled: true, side: .right, width: 0.3, strength: 0.8)
        let first = ScanPage(name: "first.png", storedFile: "page.png", edits: edits, reviewed: false, hasBeenEdited: true)
        let second = ScanPage(name: "second.png", storedFile: "page.png")
        let missing = ScanPage(name: "missing.png", storedFile: "missing.png", reviewed: false)
        let done = ScanPage(name: "done.png", storedFile: "page.png", edits: edits, reviewed: true, hasBeenEdited: true)
        library.state = LibraryState(pages: [first, second, missing, done], selection: first.id)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(library.state.pages)
        library.straightenAndCropAll()
        XCTAssertTrue(library.busy)
        library.undo() // No partial undo while processing.
        for _ in 0..<1500 {
            if !library.busy { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(library.busy)
        XCTAssertEqual(try encoder.encode(library.state.pages[3]), try encoder.encode(done))
        XCTAssertNotEqual(library.state.pages[0].edits.angle, 4)
        XCTAssertGreaterThan(library.state.pages[0].edits.right, 0.06)
        XCTAssertGreaterThan(library.state.pages[1].edits.right, 0.06)
        XCTAssertFalse(library.state.pages[0].reviewed)
        XCTAssertTrue(library.state.pages[1].hasBeenEdited == true)
        XCTAssertEqual(library.state.pages[0].edits.spineSettings, edits.spineSettings)
        XCTAssertEqual(try encoder.encode(library.state.pages[2]), try encoder.encode(missing))
        XCTAssertTrue(library.error?.contains("missing.png") == true)
        library.state.selection = second.id
        library.undo()
        XCTAssertEqual(try encoder.encode(library.state.pages), before)
        let saved = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
        XCTAssertEqual(try encoder.encode(saved.pages), before)
        XCTAssertEqual(library.state.selection, second.id)
    }
}
