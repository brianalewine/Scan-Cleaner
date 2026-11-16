import XCTest
import CoreImage
@testable import ScanCleaner

final class SpineTests: XCTestCase {
    @MainActor func testExplicitDefaultsPreserveDonePagesCheckboxAndSide() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = Library(root: root)
        var source = ScanPage(name: "source", storedFile: "source")
        source.edits.spineSettings = SpineSettings(enabled: true, side: .right, width: 0.4, strength: 0.9)
        var unfinished = ScanPage(name: "unfinished", storedFile: "unfinished")
        unfinished.edits.left = 0.1
        unfinished.hasBeenEdited = true
        var done = unfinished; done.id = UUID(); done.reviewed = true
        library.state = LibraryState(pages: [source, unfinished, done], selection: source.id)
        library.setDefaultSpineShadow()
        let updated = library.resolvedEdits(for: library.state.pages[1])
        XCTAssertEqual(updated.left, 0.1)
        XCTAssertEqual(updated.spineSettings.width, 0.4)
        XCTAssertEqual(updated.spineSettings.strength, 0.9)
        XCTAssertFalse(updated.spineSettings.enabled)
        XCTAssertEqual(updated.spineSettings.side, .left)
        XCTAssertEqual(library.state.pages[2].edits, done.edits)
        library.undo()
        XCTAssertNil(library.state.spineDefaults)
        XCTAssertEqual(library.state.pages[1].edits, unfinished.edits)
        library.redo()
        XCTAssertEqual(library.state.pages[1].edits, updated)
        let reopened = Library(root: root)
        let imported = ScanPage(name: "new", storedFile: "new")
        XCTAssertEqual(reopened.resolvedEdits(for: imported).spineSettings.width, 0.4)
        XCTAssertFalse(reopened.resolvedEdits(for: imported).spineSettings.enabled)
    }

    @MainActor func testSliderHistoryGroupsUpdatesAndClearsRedoOnNewEdit() {
        let library = Library(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let page = ScanPage(name: "page", storedFile: "page")
        library.state = LibraryState(pages: [page], selection: page.id)
        let original = library.edits
        library.beginSliderEdit()
        for angle in [1.0, 2.0, 3.0] {
            var edits = library.edits; edits.angle = angle; library.edit(edits)
        }
        library.endSliderEdit()
        library.undo()
        XCTAssertEqual(library.edits, original)
        library.redo()
        XCTAssertEqual(library.edits.angle, 3)
        library.undo()
        var crop = library.edits; crop.left = 0.2; library.edit(crop)
        library.redo()
        XCTAssertEqual(library.edits.left, 0.2)
        XCTAssertEqual(library.edits.angle, 0)
        library.undo()
        XCTAssertEqual(library.edits, original)
    }

    func testOldLibraryDecodesAndKeepsExistingCorrection() throws {
        let json = """
        {"pages":[{"id":"00000000-0000-0000-0000-000000000001","name":"old.png","storedFile":"old.png","reviewed":false,"edits":{"angle":0,"left":0,"right":0,"top":0,"bottom":0,"shadow":0.7,"quarterTurns":0}}]}
        """
        let state = try JSONDecoder().decode(LibraryState.self, from: Data(json.utf8))
        XCTAssertTrue(state.pages[0].isAdjusted)
        XCTAssertTrue(state.pages[0].edits.spineSettings.enabled)
        XCTAssertEqual(state.pages[0].edits.spineSettings.strength, 0.7)
        XCTAssertNil(state.pages[0].edits.spine)
    }

    func testSideWidthAndOffActuallyChangePixels() throws {
        let input = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        let source = try XCTUnwrap(Imaging.context.createCGImage(input, from: input.extent))
        func samples(_ settings: SpineSettings) throws -> [UInt8] {
            var edits = PageEdits(); edits.spineSettings = settings
            let result = try XCTUnwrap(Imaging.render(source, edits: edits, crop: true))
            var data = [UInt8](repeating: 0, count: 200*100*4)
            data.withUnsafeMutableBytes { bytes in
                Imaging.context.render(CIImage(cgImage: result), toBitmap: bytes.baseAddress!, rowBytes: 800, bounds: CGRect(x: 0, y: 0, width: 200, height: 100), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            return [5, 50, 100, 195].map { data[(50*200+$0)*4] }
        }
        let off = try samples(SpineSettings())
        let left = try samples(SpineSettings(enabled: true, side: .left, width: 0.2, strength: 1))
        let right = try samples(SpineSettings(enabled: true, side: .right, width: 0.2, strength: 1))
        let wide = try samples(SpineSettings(enabled: true, side: .left, width: 0.6, strength: 1))
        XCTAssertGreaterThan(left[0], off[0])
        XCTAssertEqual(left[3], off[3]); XCTAssertEqual(left[1], off[1])
        XCTAssertGreaterThan(right[3], off[3]); XCTAssertEqual(right[0], off[0])
        XCTAssertGreaterThan(wide[1], left[1])
        XCTAssertEqual(try samples(SpineSettings(enabled: false, side: .right, width: 0.6, strength: 1)), off)
    }
}
