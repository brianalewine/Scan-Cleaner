import XCTest
import AppKit
import SwiftUI
import PDFKit
import ImageIO
@testable import ScanCleaner

final class PDFExportTests: XCTestCase {
    @MainActor func testLibraryMigrationPreservesDataAndExistingDestination() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let legacy = support.appendingPathComponent("Scan Tidy")
        let destination = support.appendingPathComponent("Scan Cleaner")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let contents = Data("saved progress".utf8)
        try contents.write(to: legacy.appendingPathComponent("library.json"))
        try Library.migrateLibrary(in: support)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("library.json")), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Library.migrateLibrary(in: support)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("library.json")), contents)
    }
    func testLCSHSubjects() throws {
        let xml = """
        <record xmlns="http://www.loc.gov/MARC21/slim">
          <datafield tag="650" ind2="0"><subfield code="a">Books</subfield><subfield code="x">History</subfield><subfield code="0">authority-id</subfield></datafield>
          <datafield tag="650" ind2="0"><subfield code="a">Books</subfield><subfield code="x">History</subfield></datafield>
          <datafield tag="650" ind2="2"><subfield code="a">Other vocabulary</subfield></datafield>
          <datafield tag="653"><subfield code="a">Book history</subfield><subfield code="a">Book history</subfield><subfield code="0">ignore-id</subfield></datafield>
        </record>
        """
        XCTAssertEqual(try BookInformation.subjects(from: Data(xml.utf8)), "Books — History")
        XCTAssertEqual(try BookInformation.keywords(from: Data(xml.utf8)), "Book history")
        XCTAssertEqual(try BookInformation.keywords(from: Data("<record/>".utf8)), "")
        XCTAssertEqual(try BookInformation.subjects(from: Data("<record/>".utf8)), "")
        XCTAssertThrowsError(try BookInformation.subjects(from: Data("<response><diagnostic/></response>".utf8)))
    }
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
        let full = try PDFExporter.page(page, originals: originals, settings: PDFSettings(compression: .jpeg))
        let small = try PDFExporter.page(page, originals: originals, settings: PDFSettings(dpi: 150, quality: 0.65, grayscale: true, compression: .jpeg))
        XCTAssertLessThan(small.imageBytes, full.imageBytes)
        XCTAssertEqual(small.image.width, full.image.width / 2)
        XCTAssertEqual(small.size, full.size)
        let jpeg = try XCTUnwrap(CGImageSourceCreateWithData(small.layers[0].data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(jpeg, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyExifDictionary as String])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try CleanPDFWriter(url: url)
        try writer.add(page: small, text: [("Café naïve Straße", CGRect(x: 0.1, y: 0.5, width: 0.7, height: 0.03))])
        try writer.finish(book: BookInformation())
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: url)).string?.contains("Café naïve Straße") == true)
    }
    @MainActor func testComparisonMirrorsCursorZoomAndPan() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 1000,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let view = PDFComparisonView(frame: CGRect(x: 0, y: 0, width: 760, height: 420))
        view.update(original: image, compressed: image, fitRequest: 0)
        view.layoutSubtreeIfNeeded()
        let left = try XCTUnwrap(view.left.documentView as? PDFPreviewImageView)
        let right = try XCTUnwrap(view.right.documentView as? PDFPreviewImageView)
        let anchor = CGPoint(x: 90, y: 130)
        let oldSize = left.imageSize
        let viewport = view.left.contentView.bounds.size
        let oldOrigin = view.left.contentView.bounds.origin
        let expected = CursorZoomGeometry.origin(oldImage: oldSize,
            newImage: CGSize(width: oldSize.width * 2, height: oldSize.height * 2),
            viewport: viewport, oldOrigin: oldOrigin, anchor: anchor)
        view.magnify(factor: 2, anchor: anchor, from: view.left)
        XCTAssertEqual(left.imageSize, right.imageSize)
        XCTAssertEqual(view.left.contentView.bounds.origin.x, expected.x, accuracy: 1)
        XCTAssertEqual(view.left.contentView.bounds.origin.y, expected.y, accuracy: 1)
        XCTAssertEqual(view.left.contentView.bounds.origin, view.right.contentView.bounds.origin)
        view.right.contentView.scroll(to: CGPoint(x: 220, y: 250))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.right.contentView)
        XCTAssertEqual(view.left.contentView.bounds.origin, view.right.contentView.bounds.origin)
        view.magnify(factor: 1.5, anchor: anchor, from: view.right)
        XCTAssertEqual(left.imageSize, right.imageSize)
        XCTAssertEqual(view.left.contentView.bounds.origin, view.right.contentView.bounds.origin)
        view.update(original: image, compressed: image, fitRequest: 1)
        XCTAssertEqual(left.imageSize, oldSize)
        XCTAssertEqual(view.left.contentView.bounds.origin, view.right.contentView.bounds.origin)
    }
    func testCompressionPreviewUsesExportJPEG() throws {
        let page = ScanPage(name: "scan", storedFile: "01-narratives.png")
        let originals = workspace.appendingPathComponent("TestScans")
        let settings = PDFSettings(dpi: 150, quality: 0.5, grayscale: true, compression: .jpeg, useScanDPI: false)
        let preview = try PDFExporter.preview(page, originals: originals, settings: settings)
        let exported = try PDFExporter.page(page, originals: originals, settings: settings)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(exported.layers[0].data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(preview.compressed.width, preview.original.width / 2)
        XCTAssertEqual(preview.compressed.height, preview.original.height / 2)
        XCTAssertEqual(preview.bytes, exported.imageBytes)
        XCTAssertEqual(preview.compressed.dataProvider?.data as Data?, decoded.dataProvider?.data as Data?)
        XCTAssertThrowsError(try PDFExporter.preview(ScanPage(name: "missing", storedFile: "missing"), originals: originals, settings: settings))
    }
    func testMissingPageFailsInsteadOfSkipping() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try PDFExporter.write(pages: [ScanPage(name: "missing", storedFile: "missing")], originals: workspace, settings: PDFSettings(), book: BookInformation(), to: url) { _ in })
    }
    func testAdaptiveKeepsGrayscalePhotoInAColorBook() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 200, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        for x in 0..<256 {
            context.setFillColor(gray: CGFloat(x) / 255, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: 200))
        }
        let page = ScanPage(name: "Grayscale plate", storedFile: "plate.png")
        try Imaging.writePNG(try XCTUnwrap(context.makeImage()), to: directory.appendingPathComponent(page.storedFile))
        let encoded = try PDFExporter.page(page, originals: directory, settings: PDFSettings(photoScale: 0.5))
        XCTAssertEqual(encoded.layers.count, 1)
        XCTAssertTrue(try XCTUnwrap(encoded.layers.first).grayscale)
        XCTAssertEqual(encoded.layers.first?.width, 128)
    }
    @MainActor func testExportScreenLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root: root)
        library.state.pages = [ScanPage(name: "Sample", storedFile: "sample", reviewed: true)]
        library.showingPDFExport = true
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: ContentView().environmentObject(library).environmentObject(Projects(root: root.appendingPathComponent("ProjectLibrary"))))
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
