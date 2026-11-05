import XCTest
import AppKit
import SwiftUI
import PDFKit
import ImageIO
@testable import ScanTidy

final class PDFExportTests: XCTestCase {
    var workspace: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func testISBNChecksumsAndLegacyState() throws {
        XCTAssertEqual(BookInformation.normalizedISBN("978-0-14-032872-1"), "9780140328721")
        XCTAssertEqual(BookInformation.normalizedISBN("0-8044-2957-X"), "080442957X")
        XCTAssertNil(BookInformation.normalizedISBN("9780140328722"))
        XCTAssertNil(BookInformation.normalizedISBN("123"))
        let legacy = try JSONDecoder().decode(LibraryState.self, from: Data("{\"pages\":[]}".utf8))
        XCTAssertNil(legacy.pdfSettings)
    }
    @MainActor func testExportReadinessAndSettingsPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        XCTAssertFalse(library.readyForPDF)
        library.state.pages = [ScanPage(name: "a", storedFile: "a")]
        library.state.selection = library.state.pages[0].id
        XCTAssertFalse(library.readyForPDF)
        library.markNext(); XCTAssertTrue(library.readyForPDF)
        library.state.pdfSettings = PDFSettings(dpi: 200, grayscale: true)
        library.state.bookInformation = BookInformation(title: "Test Book")
        library.save()
        let restored = Library(root: root)
        XCTAssertEqual(restored.state.pdfSettings, library.state.pdfSettings)
        XCTAssertEqual(restored.state.bookInformation, library.state.bookInformation)
        var edits = library.edits; edits.left = 0.1; library.edit(edits)
        XCTAssertFalse(library.readyForPDF)
    }
    func testPDFRenderingOCRAndMetadata() throws {
        let output = workspace.appendingPathComponent("TestResults")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let page = ScanPage(name: "private-original-filename", storedFile: "01-narratives.png")
        let file = output.appendingPathComponent("export-verification.pdf")
        let settings = PDFSettings()
        try PDFExporter.write(pages: [page], originals: workspace.appendingPathComponent("TestScans"), settings: settings,
                              book: BookInformation(isbn: "9780140328721", title: "Export Verification", author: "René Test"), to: file) { _ in }
        let pdf = try XCTUnwrap(PDFDocument(url: file))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertGreaterThan(pdf.string?.count ?? 0, 200)
        XCTAssertEqual(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Export Verification")
        XCTAssertEqual(pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "René Test")
        let raw = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        for forbidden in ["/Producer", "/Creator", "/CreationDate", "/ModDate", "/Metadata", "private-original-filename"] { XCTAssertFalse(raw.contains(forbidden), forbidden) }
        let thumbnail = try XCTUnwrap(pdf.page(at: 0)).thumbnail(of: CGSize(width: 900, height: 1200), for: .mediaBox)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(thumbnail.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("pdf-export-preview.png"))
        let estimate = try PDFExporter.estimate(pages: [page], originals: workspace.appendingPathComponent("TestScans"), settings: settings)
        let actual = Int64(try Data(contentsOf: file).count)
        XCTAssertLessThan(abs(estimate - actual), actual / 4)
    }
    func testCompressionAndUnicodeText() throws {
        let page = ScanPage(name: "scan", storedFile: "01-narratives.png")
        let originals = workspace.appendingPathComponent("TestScans")
        let full = try PDFExporter.page(page, originals: originals, settings: PDFSettings())
        let small = try PDFExporter.page(page, originals: originals, settings: PDFSettings(dpi: 150, quality: 0.65, grayscale: true))
        XCTAssertLessThan(small.1.count, full.1.count)
        XCTAssertEqual(small.0.width, full.0.width / 2)
        XCTAssertEqual(small.2, full.2)
        let jpeg = try XCTUnwrap(CGImageSourceCreateWithData(small.1 as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(jpeg, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyExifDictionary as String])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try CleanPDFWriter(url: url)
        try writer.add(image: small.0, jpeg: small.1, size: small.2, text: [("Café naïve Straße", CGRect(x: 0.1, y: 0.5, width: 0.7, height: 0.03))], grayscale: true)
        try writer.finish(book: BookInformation())
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: url)).string?.contains("Café naïve Straße") == true)
    }
    func testMissingPageFailsInsteadOfSkipping() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try PDFExporter.write(pages: [ScanPage(name: "missing", storedFile: "missing")], originals: workspace, settings: PDFSettings(), book: BookInformation(), to: url) { _ in })
    }
    @MainActor func testExportScreenLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        library.state.pages = [ScanPage(name: "Sample", storedFile: "sample", reviewed: true)]
        library.showingPDFExport = true
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: ContentView().environmentObject(library))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        hosting.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.frame = CGRect(x: 0, y: 0, width: 1320, height: 900)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: workspace.appendingPathComponent("TestResults/pdf-settings-preview.png"))
    }
}
