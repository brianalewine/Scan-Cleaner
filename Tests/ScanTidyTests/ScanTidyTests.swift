import XCTest
@testable import ScanTidy
import AppKit
import SwiftUI

final class ScanTidyTests: XCTestCase {
    @MainActor func testThumbnailReflectsCropAndRotationAndUsesCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = Library(root: root)
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: workspace.appendingPathComponent("TestScans/01-narratives.png"), to: root.appendingPathComponent("Originals/sample.png"))
        let page = ScanPage(name: "sample.png", storedFile: "sample.png")
        let originalResult = await library.thumbnail(for: page, edits: PageEdits())
        let original = try XCTUnwrap(originalResult)
        XCTAssertLessThanOrEqual(max(original.width, original.height), 160)
        XCTAssertGreaterThan(original.height, original.width)
        var edits = PageEdits(); edits.quarterTurns = 1; edits.left = 0.1; edits.right = 0.1
        let editedResult = await library.thumbnail(for: page, edits: edits)
        let edited = try XCTUnwrap(editedResult)
        XCTAssertGreaterThan(edited.width, edited.height)
        let cached = await library.thumbnail(for: page, edits: edits)
        XCTAssertTrue(edited === cached)
    }

    @MainActor func testSeparateCropAndRotationResets() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = Library(root: root)
        var edits = PageEdits()
        edits.left = 0.1; edits.right = 0.08; edits.top = 0.03; edits.bottom = 0.02
        edits.angle = 2; edits.quarterTurns = 1
        edits.spineSettings = SpineSettings(enabled: true, side: .right, width: 0.3, strength: 0.8)
        let first = ScanPage(name: "first.png", storedFile: "first.png", edits: edits)
        let second = ScanPage(name: "second.png", storedFile: "second.png", edits: edits)
        library.state = LibraryState(pages: [first, second], selection: first.id)
        library.resetCrop()
        XCTAssertEqual(library.edits.cropRect, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(library.edits.angle, 2)
        XCTAssertEqual(library.edits.quarterTurns, 1)
        library.undo()
        XCTAssertEqual(library.edits, edits)
        library.resetRotation()
        XCTAssertEqual(library.edits.angle, 0)
        XCTAssertEqual(library.edits.quarterTurns, 0)
        XCTAssertEqual(library.edits.cropRect, edits.cropRect)
        XCTAssertEqual(library.edits.spineSettings, edits.spineSettings)
        XCTAssertEqual(library.state.pages[1].edits, edits)
        XCTAssertEqual(Library(root: root).state.pages[0].edits, library.edits)
    }

    func testAutoCropExcludesVisibleStackInSample() throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try XCTUnwrap(Imaging.load(workspace.appendingPathComponent("TestScans/01-narratives.png"), maxSize: 1800))
        let result = Imaging.autoCrop(source, edits: PageEdits())
        print("AUTO CROP sample: \(result.edits.cropRect)")
        XCTAssertTrue(result.found)
        XCTAssertGreaterThan(result.edits.right, 0.06)
        XCTAssertLessThan(result.edits.right, 0.12)
        XCTAssertEqual(result.edits.angle, 0)
        XCTAssertEqual(result.edits.quarterTurns, 0)
    }

    func testAutoCropPreservesRotationAndShadowAndLeavesBlankImageAlone() throws {
        let blank = CIImage(color: CIColor.white).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let source = try XCTUnwrap(Imaging.context.createCGImage(blank, from: blank.extent))
        var edits = PageEdits(); edits.angle = 1.5; edits.quarterTurns = 1
        edits.left = 0.07
        edits.spineSettings = SpineSettings(enabled: true)
        let result = Imaging.autoCrop(source, edits: edits)
        XCTAssertFalse(result.found)
        XCTAssertEqual(result.edits, edits)
    }

    @MainActor func testReorderPreservesPageSettingsSelectionAndSavedOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = Library(root: root)
        var pages = (0..<4).map { ScanPage(name: "\($0).png", storedFile: "\($0).png") }
        pages[1].edits.angle = 1.25
        pages[1].reviewed = true
        library.state = LibraryState(pages: pages, selection: pages[1].id)
        library.movePages(from: IndexSet(integer: 1), to: 4)
        XCTAssertEqual(library.state.pages.map(\.id), [pages[0].id, pages[2].id, pages[3].id, pages[1].id])
        XCTAssertEqual(library.index, 3)
        XCTAssertEqual(library.page?.edits, pages[1].edits)
        XCTAssertEqual(library.page?.reviewed, true)
        let reopened = Library(root: root)
        XCTAssertEqual(reopened.state.pages.map(\.id), library.state.pages.map(\.id))
        XCTAssertEqual(reopened.state.selection, pages[1].id)
        library.movePages(from: IndexSet(integer: 3), to: 0)
        XCTAssertEqual(library.state.pages.first?.id, pages[1].id)
        library.busy = true
        library.movePages(from: IndexSet(integer: 0), to: 4)
        XCTAssertEqual(library.state.pages.first?.id, pages[1].id)
    }

    @MainActor func testDeletePageSelectionAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = Library(root: root)
        let pages = (0..<3).map { ScanPage(name: "\($0).png", storedFile: "\($0).png") }
        library.state = LibraryState(pages: pages, selection: pages[1].id)
        library.busy = true
        library.deletePage()
        XCTAssertEqual(library.state.pages.count, 3)
        library.busy = false
        library.deletePage()
        XCTAssertEqual(library.state.pages.map(\.id), [pages[0].id, pages[2].id])
        XCTAssertEqual(library.state.selection, pages[2].id)
        let reopened = Library(root: root)
        XCTAssertEqual(reopened.state.pages.map(\.id), [pages[0].id, pages[2].id])
        XCTAssertEqual(reopened.state.selection, pages[2].id)
        library.deletePage()
        XCTAssertEqual(library.state.selection, pages[0].id)
        library.deletePage()
        XCTAssertTrue(library.state.pages.isEmpty)
        XCTAssertNil(library.state.selection)
        XCTAssertNil(library.preview)
        library.deletePage() // Empty libraries are safe.
        XCTAssertTrue(Library(root: root).state.pages.isEmpty)
    }

    func testCropBoundsAndRoundTrip() throws {
        var e = PageEdits()
        e.setCrop(CGRect(x: -0.1, y: 0.1, width: 0.9, height: 0.8))
        XCTAssertEqual(e.left, 0)
        XCTAssertEqual(e.right, 0.2, accuracy: 0.0001)
        XCTAssertEqual(e.cropRect.height, 0.8, accuracy: 0.0001)
        let before = e
        e.setCrop(CGRect(x: 0, y: 0, width: 0.001, height: 0.001))
        XCTAssertEqual(before, e)
        XCTAssertEqual(try JSONDecoder().decode(PageEdits.self, from: JSONEncoder().encode(e)), e)
    }
    @MainActor func testRestoresSelectionEditsAndReviewedStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = Library(root: root)
        var e = PageEdits(); e.left = 0.08; e.angle = -0.45; e.shadow = 0.7
        let first = ScanPage(name: "first.png", storedFile: "first.png")
        let second = ScanPage(name: "second.png", storedFile: "second.png", edits: e, reviewed: true)
        library.state = LibraryState(pages: [first, second], selection: second.id)
        library.grid = false; library.croppedPreview = true; library.save()
        let reopened = Library(root: root)
        XCTAssertEqual(reopened.state.selection, second.id)
        XCTAssertEqual(reopened.edits, e)
        XCTAssertEqual(reopened.page?.reviewed, true)
        XCTAssertNil(reopened.error)
        XCTAssertFalse(reopened.grid)
        XCTAssertTrue(reopened.croppedPreview)
    }
    func testTextDeskewFindsKnownRotation() throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try XCTUnwrap(Imaging.load(workspace.appendingPathComponent("TestScans/01-narratives.png"), maxSize: 1200))
        let initial = Imaging.textAngle(source)
        var e = PageEdits(); e.angle = 2
        let tilted = try XCTUnwrap(Imaging.render(source, edits: e, crop: false))
        let correction = Imaging.textAngle(tilted)
        print("DESKEW initial=\(initial) rotated=\(correction)")
        XCTAssertEqual(correction, initial - 2, accuracy: 0.25)
    }
    @MainActor func testWindowLayoutSnapshot() throws {
        _ = NSApplication.shared
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let library = Library(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let page = ScanPage(name: "01-narratives.png", storedFile: "sample.png")
        library.state = LibraryState(pages: [page], selection: page.id)
        library.preview = try XCTUnwrap(Imaging.load(workspace.appendingPathComponent("TestScans/01-narratives.png"), maxSize: 1600))
        library.status = "Ready · draw a crop or suggest an angle"
        let hosting = NSHostingView(rootView: ContentView().environmentObject(library))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        hosting.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 1320, height: 900)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let output = workspace.appendingPathComponent("TestResults")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("app-preview.png"))
    }
    func testUserScansRenderAndExport() throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = workspace.appendingPathComponent("TestResults")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, left, right, angle) in [("01-narratives", 0.027, 0.07, -0.3), ("02-notes", 0.075, 0.012, -0.1)] {
            let url = workspace.appendingPathComponent("TestScans/\(name).png")
            let source = try XCTUnwrap(Imaging.load(url))
            var e = PageEdits(); e.left = left; e.right = right; e.top = 0.012; e.bottom = 0.012; e.angle = angle; e.shadow = 0.65
            let autoSource = try XCTUnwrap(Imaging.load(url, maxSize: 1600))
            e.angle = Imaging.textAngle(autoSource)
            XCTAssertNotNil(Imaging.shadowKernel)
            let result = try XCTUnwrap(Imaging.render(source, edits: e, crop: true))
            XCTAssertGreaterThan(result.width, 4000)
            XCTAssertLessThan(result.width, source.width)
            try Imaging.writePNG(result, to: output.appendingPathComponent("\(name)-cleaned.png"))
            let preview = try XCTUnwrap(Imaging.load(url, maxSize: 1600))
            let auto = Imaging.autoAdjust(preview, edits: PageEdits())
            print("AUTO \(name): found=\(auto.found) angle=\(auto.edits.angle) left=\(auto.edits.left) right=\(auto.edits.right)")
            let small = try XCTUnwrap(Imaging.load(output.appendingPathComponent("\(name)-cleaned.png"), maxSize: 1400))
            try Imaging.writePNG(small, to: output.appendingPathComponent("\(name)-preview.png"))
        }
    }
}
