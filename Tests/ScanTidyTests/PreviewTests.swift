import XCTest
import CoreImage
@testable import ScanTidy

final class PreviewTests: XCTestCase {
    @MainActor func testRapidEditsRenderAndSaveLatestValue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        let input = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        let source = try XCTUnwrap(Imaging.context.createCGImage(input, from: input.extent))
        try Imaging.writePNG(source, to: root.appendingPathComponent("Originals/page.png"))
        let page = ScanPage(name: "page.png", storedFile: "page.png")
        library.state = LibraryState(pages: [page], selection: page.id)
        library.select(page.id)
        for _ in 0..<100 {
            if library.preview != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(library.preview)
        library.croppedPreview = true
        var updatedWhileDragging = false
        for step in 1...40 {
            var edits = library.edits
            edits.left = Double(step) / 100
            library.edit(edits)
            try await Task.sleep(nanoseconds: 5_000_000)
            if let width = library.preview?.width, width < 200 && step < 40 {
                updatedWhileDragging = true
            }
        }
        XCTAssertTrue(updatedWhileDragging, "The preview should update before slider movement stops")
        for _ in 0..<100 {
            if library.preview?.width == 120 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(library.preview?.width, 120)
        try await Task.sleep(nanoseconds: 350_000_000)
        let saved = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
        XCTAssertEqual(saved.pages.first?.edits.left, 0.4)
    }
}
