import XCTest
import CoreImage
@testable import ScanTidy

final class SpineTests: XCTestCase {
    @MainActor func testDefaultsOnlyFollowUntouchedPagesAndPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = Library(root: root)
        let pages = (0..<4).map { ScanPage(name: "\($0).png", storedFile: "\($0).png") }
        library.state = LibraryState(pages: pages, selection: pages[0].id)
        XCTAssertFalse(library.edits.spineSettings.enabled)
        var crop = library.edits; crop.left = 0.1
        library.edit(crop) // Even a crop edit protects this page's shadow settings.
        library.state.selection = pages[1].id
        var settings = SpineSettings(enabled: true, side: .right, width: 0.18, strength: 0.8)
        library.editSpine(settings)
        XCTAssertFalse(library.resolvedEdits(for: library.state.pages[0]).spineSettings.enabled)
        var inherited = settings; inherited.enabled = false
        XCTAssertEqual(library.resolvedEdits(for: library.state.pages[2]).spineSettings, inherited)
        library.state.selection = pages[2].id
        library.markNext() // A reviewed page also keeps its accepted settings.
        settings.width = 0.4; settings.side = .left; settings.enabled = false
        library.editSpine(settings)
        XCTAssertEqual(library.resolvedEdits(for: library.state.pages[1]).spineSettings.width, 0.18)
        XCTAssertFalse(library.resolvedEdits(for: library.state.pages[2]).spineSettings.enabled)
        let newlyImported = ScanPage(name: "new.png", storedFile: "new.png")
        library.state.pages.append(newlyImported); library.save()
        let reopened = Library(root: root)
        XCTAssertEqual(reopened.resolvedEdits(for: newlyImported).spineSettings, settings)
        XCTAssertEqual(reopened.state.spineDefaults, settings)
        XCTAssertEqual(reopened.resolvedEdits(for: reopened.state.pages[1]).spineSettings.side, .right)
    }

    @MainActor func testDefaultsPreserveBothCheckboxStates() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = Library(root: root)
        let selected = ScanPage(name: "selected.png", storedFile: "selected.png")
        var enabled = ScanPage(name: "enabled.png", storedFile: "enabled.png")
        enabled.edits.spineSettings = SpineSettings(enabled: true)
        enabled.hasBeenEdited = false
        let disabled = ScanPage(name: "disabled.png", storedFile: "disabled.png")
        library.state = LibraryState(pages: [selected, enabled, disabled], selection: selected.id)

        for isEnabled in [true, false] {
            let settings = SpineSettings(enabled: isEnabled, side: .right, width: 0.4, strength: 0.9)
            library.editSpine(settings)
            XCTAssertEqual(library.edits.spineSettings, settings)
            for (index, expectedEnabled) in [(1, true), (2, false)] {
                var expected = settings; expected.enabled = expectedEnabled
                XCTAssertEqual(library.resolvedEdits(for: library.state.pages[index]).spineSettings, expected)
            }
            let imported = ScanPage(name: "new.png", storedFile: "new.png")
            XCTAssertFalse(library.resolvedEdits(for: imported).spineSettings.enabled)
            let reopened = Library(root: root)
            XCTAssertTrue(reopened.resolvedEdits(for: reopened.state.pages[1]).spineSettings.enabled)
            XCTAssertFalse(reopened.resolvedEdits(for: reopened.state.pages[2]).spineSettings.enabled)
        }
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
