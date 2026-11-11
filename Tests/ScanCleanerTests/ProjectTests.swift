import XCTest
@testable import ScanCleaner

final class ProjectTests: XCTestCase {
    @MainActor func testProjectsKeepIndependentProgressAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = Projects(root: root)
        projects.create(name: "First book")
        let first = try XCTUnwrap(projects.activeID)
        var page = ScanPage(name: "page", storedFile: "page.png")
        page.edits.angle = 2.5
        page.reviewed = true
        projects.active.state.pages = [page]
        projects.active.state.selection = page.id
        projects.create(name: "Second book")
        XCTAssertTrue(projects.active.state.pages.isEmpty)
        XCTAssertEqual(projects.items.first(where: { $0.id == first })?.pageCount, 1)
        projects.open(first)
        XCTAssertEqual(projects.active.state.pages.first?.edits.angle, 2.5)
        XCTAssertTrue(projects.active.state.pages.first?.reviewed == true)
        XCTAssertEqual(projects.active.state.selection, page.id)
        XCTAssertTrue(projects.save())
        let restored = Projects(root: root)
        XCTAssertEqual(restored.items.count, 2)
        restored.open(first)
        XCTAssertEqual(restored.active.state.pages.count, 1)
    }

    @MainActor func testRenamePersistsAndLibraryNavigationKeepsProgress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = Projects(root: root)
        projects.create(name: "Before")
        let id = try XCTUnwrap(projects.activeID)
        XCTAssertFalse(projects.showingLibrary)
        var page = ScanPage(name: "first", storedFile: "first.png")
        page.reviewed = true
        projects.active.state.pages = [page]
        projects.rename(id, to: "  Renamed Book  ")
        projects.showLibrary()
        XCTAssertTrue(projects.showingLibrary)
        XCTAssertEqual(projects.savedState(for: id)?.pages.first?.id, page.id)
        projects.open(id)
        XCTAssertFalse(projects.showingLibrary)
        XCTAssertEqual(projects.activeName, "Renamed Book")
        let restored = Projects(root: root)
        XCTAssertFalse(restored.showingLibrary)
        XCTAssertEqual(restored.activeName, "Renamed Book")
        XCTAssertTrue(restored.active.readyForPDF)
        projects.rename(id, to: "   ")
        XCTAssertEqual(projects.activeName, "Renamed Book")
    }

    @MainActor func testRestoresActiveProjectAndLibraryRoute() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = Projects(root: root)
        projects.create(name: "First")
        let first = try XCTUnwrap(projects.activeID)
        projects.create(name: "Second")
        projects.open(first)
        projects.active.state.zoom = 2
        XCTAssertTrue(projects.save())
        let editor = Projects(root: root)
        XCTAssertEqual(editor.activeID, first)
        XCTAssertFalse(editor.showingLibrary)
        XCTAssertEqual(editor.active.state.zoom, 2)
        projects.showLibrary()
        let library = Projects(root: root)
        XCTAssertTrue(library.showingLibrary)
        XCTAssertEqual(library.activeID, first)
    }

    func testStorageIncludesOriginalsAndEditFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Originals"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 100_000).write(to: root.appendingPathComponent("Originals/scan.png"))
        let metadata = Data("{\"pages\":[]}".utf8)
        try metadata.write(to: root.appendingPathComponent("library.json"))
        let usage = ProjectStorage.measure(root)
        XCTAssertGreaterThan(usage.total, 0)
        XCTAssertEqual(usage.edits, Int64(metadata.count))
        let originalSize = try root.appendingPathComponent("Originals/scan.png").resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
        XCTAssertGreaterThanOrEqual(usage.total, Int64(originalSize))
    }

    @MainActor func testLegacyProgressMigratesOnceAndKeepsOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = Library(root: root)
        legacy.state.pages = [ScanPage(name: "original", storedFile: "scan.png")]
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("Originals/scan.png"))
        legacy.save()
        let projects = Projects(root: root)
        XCTAssertEqual(projects.items.count, 1)
        XCTAssertEqual(projects.active.state.pages.count, 1)
        XCTAssertEqual(try Data(contentsOf: projects.active.root.appendingPathComponent("Originals/scan.png")), Data([1, 2, 3]))
        XCTAssertEqual(Projects(root: root).items.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Originals/scan.png").path))
    }
}
