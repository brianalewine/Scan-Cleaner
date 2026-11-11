import AppKit
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import ScanCleaner

final class AdaptivePDFTests: XCTestCase {
    // An odd width exercises scanline padding in 1-bit images.
    private let width = 901
    private let height = 1201
    private var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func bitmap() throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue))
    }

    private func scan(picture: CGRect? = nil, grayscalePicture: Bool = false, shadedPaper: Bool = false) throws -> ScanPage {
        let context = try bitmap()
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        if shadedPaper {
            let colors = [CGColor(gray: 0.88, alpha: 1), CGColor(gray: 0.96, alpha: 1)]
            let paper = try XCTUnwrap(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                 colors: colors as CFArray, locations: nil))
            context.drawLinearGradient(paper, start: .zero, end: CGPoint(x: width, y: 0), options: [])
        }
        let text = NSAttributedString(string: "Field notes on birds and flowers.",
                                      attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 32, nil),
                                                   .foregroundColor: CGColor(gray: 0, alpha: 1)])
        let line = CTLineCreateWithAttributedString(text)
        for y in stride(from: 65, to: height - 25, by: 48) {
            context.textPosition = CGPoint(x: y.isMultiple(of: 5) ? 110 : 57, y: y)
            CTLineDraw(line, context)
        }
        if let picture {
            context.saveGState()
            context.clip(to: picture)
            let colors = grayscalePicture
                ? [CGColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1),
                   CGColor(srgbRed: 0.92, green: 0.92, blue: 0.92, alpha: 1)]
                : [CGColor(srgbRed: 0.1, green: 0.22, blue: 0.73, alpha: 1),
                   CGColor(srgbRed: 0.9, green: 0.42, blue: 0.22, alpha: 1)]
            let gradient = try XCTUnwrap(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                    colors: colors as CFArray, locations: nil))
            context.drawLinearGradient(gradient, start: picture.origin,
                                       end: CGPoint(x: picture.maxX, y: picture.maxY), options: [])
            context.restoreGState()
        }
        let page = ScanPage(name: "synthetic scan", storedFile: "scan.png")
        try Imaging.writePNG(try XCTUnwrap(context.makeImage()), to: folder.appendingPathComponent(page.storedFile))
        return page
    }

    private func write(_ page: ScanPage, _ settings: PDFSettings) throws -> URL {
        let url = folder.appendingPathComponent(UUID().uuidString + ".pdf")
        try PDFExporter.write(pages: [page], originals: folder, settings: settings, book: BookInformation(), to: url) { _ in }
        return url
    }

    private func rendered(_ url: URL) throws -> CGImage {
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let page = try XCTUnwrap(document.page(at: 1))
        let context = try bitmap()
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        let pageBounds = page.getBoxRect(.mediaBox)
        context.scaleBy(x: bounds.width / pageBounds.width, y: bounds.height / pageBounds.height)
        context.drawPDFPage(page)
        return try XCTUnwrap(context.makeImage())
    }

    private func rgb(_ image: CGImage) throws -> [UInt8] {
        let context = try bitmap()
        context.draw(image, in: bounds)
        let pixels = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        return Array(UnsafeBufferPointer(start: pixels, count: context.bytesPerRow * height))
    }

    func testOlderProjectKeepsItsExportSettings() throws {
        let json = #"{"pages":[],"pdfSettings":{"dpi":225,"sourceDPI":600,"quality":0.76,"grayscale":true,"ocr":false,"language":"fr-FR"}}"#
        let library = try JSONDecoder().decode(LibraryState.self, from: Data(json.utf8))
        let legacy = try XCTUnwrap(library.pdfSettings)
        XCTAssertEqual(legacy.compression, .jpeg)
        XCTAssertEqual(legacy.dpi, 225)
        XCTAssertEqual(legacy.language, "fr-FR")
        XCTAssertTrue(legacy.grayscale)
        XCTAssertFalse(legacy.ocr)
        XCTAssertFalse(legacy.useScanDPI)
        var current = PDFSettings()
        XCTAssertEqual(current.compression, .adaptive)
        XCTAssertTrue(current.useScanDPI)
        current.photoScale = 0.5
        XCTAssertEqual(try JSONDecoder().decode(PDFSettings.self, from: JSONEncoder().encode(current)), current)
    }

    func testEmbeddedScanResolutionAndManualOverride() throws {
        let page = try scan()
        let source = try XCTUnwrap(Imaging.load(folder.appendingPathComponent(page.storedFile)))
        let tagged = ScanPage(name: "600 dpi", storedFile: "tagged.tif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(folder.appendingPathComponent(tagged.storedFile) as CFURL,
                                                                       UTType.tiff.identifier as CFString, 1, nil))
        let properties = [kCGImagePropertyDPIWidth: 600, kCGImagePropertyDPIHeight: 600]
        CGImageDestinationAddImage(destination, source, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var settings = PDFSettings(dpi: 300, sourceDPI: 300)
        let detected = try PDFExporter.page(tagged, originals: folder, settings: settings)
        XCTAssertEqual(detected.image.width, width / 2)
        XCTAssertEqual(detected.size.width, Double(width) * 72 / 600, accuracy: 0.01)
        settings.useScanDPI = false
        let manual = try PDFExporter.page(tagged, originals: folder, settings: settings)
        XCTAssertEqual(manual.image.width, width)
        XCTAssertEqual(manual.size.width, Double(width) * 72 / 300, accuracy: 0.01)
    }

    func testTextStaysSearchableAndCompressesAtTheSameResolution() throws {
        let page = try scan()
        var settings = PDFSettings()
        settings.compression = .adaptive
        let adaptiveURL = try write(page, settings)
        settings.compression = .jpeg
        let jpegURL = try write(page, settings)
        let adaptiveData = try Data(contentsOf: adaptiveURL)
        let jpegData = try Data(contentsOf: jpegURL)
        XCTAssertLessThan(adaptiveData.count, jpegData.count)
        XCTAssertTrue(String(decoding: adaptiveData, as: UTF8.self).contains("/BitsPerComponent 4"))
        let pdf = try XCTUnwrap(PDFDocument(url: adaptiveURL))
        let jpeg = try XCTUnwrap(PDFDocument(url: jpegURL))
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox), jpeg.page(at: 0)?.bounds(for: .mediaBox))
        XCTAssertTrue(pdf.string?.localizedCaseInsensitiveContains("birds and flowers") == true)

        let source = try rgb(try XCTUnwrap(Imaging.load(folder.appendingPathComponent(page.storedFile))))
        let result = try rgb(try rendered(adaptiveURL))
        var smoothEdges = 0
        var expectedInk = 0, retainedInk = 0, darkenedPaper = 0
        for i in stride(from: 0, to: source.count, by: 4) {
            if (50...190).contains(source[i]) && abs(Int(source[i]) - Int(result[i])) < 25 { smoothEdges += 1 }
            if source[i] < 30 {
                expectedInk += 1
                if result[i] < 80 { retainedInk += 1 }
            } else if source[i] > 245 && result[i] < 80 {
                darkenedPaper += 1
            }
        }
        XCTAssertGreaterThan(smoothEdges, 1000)
        XCTAssertGreaterThan(expectedInk, 10_000)
        XCTAssertGreaterThan(Double(retainedInk) / Double(expectedInk), 0.98)
        XCTAssertLessThan(darkenedPaper, expectedInk / 20)
    }

    func testMixedRegionsPreviewMatchesPDFAndRetainsColor() throws {
        let page = try scan(picture: CGRect(x: 455, y: 560, width: 420, height: 520), shadedPaper: true)
        var settings = PDFSettings()
        settings.compression = .adaptive
        settings.photoScale = 0.5
        settings.ocr = false
        let encoded = try PDFExporter.page(page, originals: folder, settings: settings)
        XCTAssertTrue(encoded.layers.contains { if case .inkShades = $0.format { return true }; return false })
        XCTAssertTrue(encoded.layers.contains { !$0.grayscale && $0.bitsPerComponent == 8 })
        XCTAssertTrue(encoded.layers.allSatisfy { $0.rect == bounds })
        let preview = try PDFExporter.preview(page, originals: folder, settings: settings)
        XCTAssertEqual(preview.bytes, encoded.imageBytes)
        XCTAssertEqual(preview.compressed.width, width)
        XCTAssertEqual(preview.compressed.height, height)
        let url = try write(page, settings)
        let output = try rgb(try rendered(url))
        let reference = try rgb(preview.original)
        let comparison = try rgb(preview.compressed)
        var picturePixels = 0, pictureError = 0, previewError = 0
        for i in stride(from: 0, to: output.count, by: 4) {
            let colorful = abs(Int(reference[i]) - Int(reference[i + 2])) > 60
            if colorful { picturePixels += 1 }
            for channel in 0..<3 {
                previewError += abs(Int(output[i + channel]) - Int(comparison[i + channel]))
                if colorful { pictureError += abs(Int(output[i + channel]) - Int(reference[i + channel])) }
            }
        }
        XCTAssertGreaterThan(picturePixels, 60_000)
        XCTAssertLessThan(Double(pictureError) / Double(3 * picturePixels), 9)
        XCTAssertLessThan(Double(previewError) / Double(3 * width * height), 2)
        // The narrow margin runs from darker to lighter paper, outside the text and illustration.
        for x in stride(from: 20, to: width, by: 75) {
            let i = 4 * (width * 12 + x)
            XCTAssertEqual(Int(output[i]), Int(reference[i]), accuracy: 7)
        }
        let estimate = try PDFExporter.estimate(pages: [page], originals: folder, settings: settings)
        XCTAssertLessThan(abs(estimate - Int64(try Data(contentsOf: url).count)), 10_000)
    }

    func testSimplificationKeepsColoredTypeAtExportResolution() throws {
        let context = try bitmap()
        context.setFillColor(gray: 0.93, alpha: 1)
        context.fill(bounds)
        let red = CGColor(srgbRed: 0.71, green: 0.04, blue: 0.1, alpha: 1)
        let title = NSAttributedString(string: "Mountain Rescue", attributes: [
            .font: CTFontCreateWithName("TimesNewRomanPSMT" as CFString, 53, nil), .foregroundColor: red
        ])
        context.textPosition = CGPoint(x: 24, y: 200)
        CTLineDraw(CTLineCreateWithAttributedString(title), context)
        let page = ScanPage(name: "Red title", storedFile: "title.png")
        try Imaging.writePNG(try XCTUnwrap(context.makeImage()), to: folder.appendingPathComponent(page.storedFile))
        let original = try rgb(try XCTUnwrap(context.makeImage()))
        var previous: Data?
        for level in [1, 3, 5, 10] {
            let settings = PDFSettings(ocr: false, photoScale: 0.5, simplification: level)
            let encoded = try PDFExporter.page(page, originals: folder, settings: settings)
            let layer = try XCTUnwrap(encoded.layers.last)
            guard case .indexed = layer.format else { return XCTFail("Expected indexed color") }
            XCTAssertEqual(layer.width, width)
            XCTAssertEqual(layer.height, height)
            let pixels = try rgb(try rendered(try write(page, settings)))
            var total = 0, retained = 0, colorError = 0
            for i in stride(from: 0, to: original.count, by: 4) where Int(original[i]) - Int(original[i+1]) > 100 {
                total += 1
                if level == 10 {
                    for c in 0..<3 { colorError += abs(Int(pixels[i+c]) - Int(original[i+c])) }
                }
                if Int(pixels[i]) - Int(pixels[i+1]) > 80 { retained += 1 }
            }
            XCTAssertGreaterThan(total, 500)
            XCTAssertGreaterThan(Double(retained) / Double(total), 0.97)
            if level == 10 { XCTAssertLessThan(Double(colorError) / Double(total * 3), 12) }
            XCTAssertNotEqual(previous, layer.data)
            previous = layer.data
        }
    }

    func testLightCaptionDoesNotPaintDarkInkAroundLetters() throws {
        let context = try bitmap()
        context.setFillColor(CGColor(srgbRed: 0.19, green: 0.22, blue: 0.25, alpha: 1))
        context.fill(bounds)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let line = NSAttributedString(string: "They sailed", attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, 54, nil),
            .foregroundColor: CGColor(gray: 1, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 150, y: 500)
        CTLineDraw(CTLineCreateWithAttributedString(line), context)
        let page = ScanPage(name: "Light caption", storedFile: "caption.png")
        let source = try XCTUnwrap(context.makeImage())
        try Imaging.writePNG(source, to: folder.appendingPathComponent(page.storedFile))
        let settings = PDFSettings(quality: 0.43, ocr: false, photoScale: 0.57, simplification: 10)
        let original = try rgb(source)
        let output = try rgb(try rendered(try write(page, settings)))
        var dark = 0, white = 0
        for y in 640..<730 {
            for x in 145..<435 {
                let i = 4 * (y * width + x)
                if original[i] > 250 && output[i] > 210 { white += 1 }
                if original[i] >= 45 && original[i] <= 52 && output[i] < 25 { dark += 1 }
            }
        }
        XCTAssertGreaterThan(white, 500)
        XCTAssertLessThan(dark, 50)
    }

    func testStrongerInkSettingsKeepPictureResolutionIndependent() throws {
        let page = try scan(picture: CGRect(x: 460, y: 520, width: 420, height: 510))
        let settings = PDFSettings(quality: 0.05, ocr: false, photoScale: 0.1, simplification: 10)
        let encoded = try PDFExporter.page(page, originals: folder, settings: settings)
        XCTAssertEqual(encoded.layers.count, 2)
        let photo = try XCTUnwrap(encoded.layers.first)
        XCTAssertEqual(photo.width, Int((Double(width) * 0.1).rounded()))
        let ink = try XCTUnwrap(encoded.layers.last)
        guard case let .indexed(last, _, _, masked) = ink.format else { return XCTFail("Expected indexed ink") }
        XCTAssertTrue(masked)
        XCTAssertTrue((1...34).contains(last))
        XCTAssertEqual(ink.width, width)
        XCTAssertEqual(ink.height, height)
        let pixels = try rgb(try rendered(try write(page, settings)))
        let original = try rgb(try XCTUnwrap(Imaging.load(folder.appendingPathComponent(page.storedFile))))
        var darkSamples = 0, legibleSamples = 0
        for y in 0..<height {
            for x in 0..<450 {
                let i = 4 * (y * width + x)
                if original[i] < 20 {
                    darkSamples += 1
                    if pixels[i] < 64 { legibleSamples += 1 }
                }
            }
        }
        XCTAssertGreaterThan(darkSamples, 500)
        XCTAssertGreaterThan(Double(legibleSamples) / Double(darkSamples), 0.99)
    }

    func testManualPaletteExportsAtSelectedResolutionWithoutSizeTarget() throws {
        let page = try scan(picture: CGRect(x: 460, y: 520, width: 420, height: 510))
        var bytesAtSix = 0
        for (index, limit) in PDFSettings.wholePagePaletteSizes.enumerated() {
            let settings = PDFSettings(ocr: false, simplification: 6 + index, simplifyPictures: true)
            XCTAssertEqual(try JSONDecoder().decode(PDFSettings.self, from: JSONEncoder().encode(settings)), settings)
            let encoded = try PDFExporter.page(page, originals: folder, settings: settings)
            XCTAssertEqual(encoded.layers.count, 1)
            let layer = try XCTUnwrap(encoded.layers.first)
            guard case let .indexed(last, _, bits, masked) = layer.format else { return XCTFail("Expected palette pixels") }
            XCTAssertLessThanOrEqual(last + 1, limit)
            XCTAssertEqual(bits, [8, 4, 4, 2, 1][index])
            XCTAssertFalse(masked)
            XCTAssertEqual(layer.width, width)
            XCTAssertEqual(layer.height, height)
            if index == 0 { bytesAtSix = layer.data.count }
            if limit == 2 {
                XCTAssertLessThan(layer.data.count, bytesAtSix)
                let pixels = try rgb(try rendered(try write(page, settings)))
                let original = try rgb(try XCTUnwrap(Imaging.load(folder.appendingPathComponent(page.storedFile))))
                // Check both ink and paper on the odd-width text side after PDF decoding.
                var ink = 0, preserved = 0, paper = 0, light = 0
                for y in 0..<height {
                    for x in 0..<450 {
                        let i = 4 * (y * width + x)
                        if original[i] < 20 { ink += 1; if pixels[i] < 128 { preserved += 1 } }
                        if original[i] > 250 { paper += 1; if pixels[i] > 160 { light += 1 } }
                    }
                }
                XCTAssertGreaterThan(ink, 500)
                XCTAssertGreaterThan(Double(preserved) / Double(ink), 0.99)
                XCTAssertGreaterThan(Double(light) / Double(paper), 0.99)
            }
        }
    }

    func testConcurrentExportMatchesSequentialPageOrderAndBudget() async throws {
        let text = try scan()
        try FileManager.default.copyItem(at: folder.appendingPathComponent(text.storedFile),
                                         to: folder.appendingPathComponent("text.png"))
        let picture = try scan(picture: bounds)
        let pages = [picture, ScanPage(name: "Text", storedFile: "text.png"), picture]
        let settings = PDFSettings(ocr: false, simplification: 5)
        let expected = folder.appendingPathComponent("serial.pdf")
        let actual = folder.appendingPathComponent("parallel.pdf")
        try PDFExporter.write(pages: pages, originals: folder, settings: settings, book: BookInformation(),
                              to: expected, maximumBytes: 100_000) { _ in }
        var progress: [Int] = []
        try await PDFExporter.writeConcurrent(pages: pages, originals: folder, settings: settings, book: BookInformation(),
                                              to: actual, maximumBytes: 100_000) { progress.append($0) }
        XCTAssertEqual(progress, [1, 2, 3])
        XCTAssertEqual(try Data(contentsOf: expected), try Data(contentsOf: actual))
    }

    func testLimitedExportMeasuresAllPagesAndPreservesOCR() throws {
        let scan = try scan(picture: CGRect(x: 460, y: 520, width: 420, height: 510))
        let pages = [scan, scan, scan]
        let url = folder.appendingPathComponent("limited.pdf")
        let settings = PDFSettings(simplification: 4)
        try PDFExporter.write(pages: pages, originals: folder, settings: settings, book: BookInformation(),
                              to: url, maximumBytes: 100_000) { _ in }
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 100_000)
        let check = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let resources = try XCTUnwrap(check.page(at: 1)?.dictionary)
        var dictionary: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(resources, "Resources", &dictionary))
        // Oversized palette pages retain an indexed image instead of a JPEG scan.
        let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(raw.contains("/Indexed"))

        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, pages.count)
        for i in pages.indices {
            XCTAssertTrue(pdf.page(at: i)?.string?.localizedCaseInsensitiveContains("birds and flowers") == true)
        }
        XCTAssertThrowsError(try PDFExporter.write(pages: pages, originals: folder, settings: settings,
                                                   book: BookInformation(), to: url, maximumBytes: 2000) { _ in })
    }

    func testJPEG2000PhotosRenderInColorAndGrayscale() throws {
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains("public.jpeg-2000") == true else {
            throw XCTSkip("The system JPEG 2000 encoder is unavailable.")
        }
        let page = try scan(picture: bounds)
        var settings = PDFSettings()
        settings.compression = .jpeg2000
        settings.ocr = false
        let original = try rgb(try XCTUnwrap(Imaging.load(folder.appendingPathComponent(page.storedFile))))
        for gray in [false, true] {
            settings.grayscale = gray
            let url = try write(page, settings)
            let data = try Data(contentsOf: url)
            XCTAssertNotNil(data.range(of: Data("/JPXDecode".utf8)))
            XCTAssertNil(data.range(of: Data("Kakadu".utf8)))
            let pixels = try rgb(try rendered(url))
            let index = 4 * (width * (height / 2) + width / 5)
            if gray {
                XCTAssertEqual(Int(pixels[index]), Int(pixels[index + 2]), accuracy: 2)
                XCTAssertTrue((30...220).contains(pixels[index]))
            } else {
                for channel in 0..<3 {
                    XCTAssertEqual(Int(pixels[index + channel]), Int(original[index + channel]), accuracy: 8)
                }
            }
        }
    }

    func testAdaptivePreservesContinuousGrayscaleShading() throws {
        let page = try scan(picture: bounds, grayscalePicture: true)
        var settings = PDFSettings()
        settings.ocr = false
        let image = try PDFExporter.page(page, originals: folder, settings: settings)
        XCTAssertTrue(image.layers.contains { $0.bitsPerComponent == 8 })
        let pixels = try rgb(try rendered(try write(page, settings)))
        let source = try rgb(try XCTUnwrap(Imaging.load(folder.appendingPathComponent(page.storedFile))))
        for y in stride(from: 25, to: height, by: 110) {
            for x in stride(from: 25, to: width, by: 100) {
                let i = 4 * (y * width + x)
                XCTAssertEqual(Int(pixels[i]), Int(source[i]), accuracy: 8)
            }
        }
    }

    func testDarkPhotoEdgeKeepsItsGrayTone() throws {
        let context = try bitmap()
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        // A light page with nontile-aligned dark artwork, like a photograph of an artifact.
        let photo = CGRect(x: 253, y: 313, width: 317, height: 335)
        context.setFillColor(gray: 0.18, alpha: 1)
        context.fill(photo)
        let split = try XCTUnwrap(AdaptiveCompression.separate(try XCTUnwrap(context.makeImage())))
        let lowerEdge = CGPoint(x: photo.midX, y: CGFloat(height) - photo.minY - 1)
        XCTAssertTrue(split.photoRects.contains { $0.contains(lowerEdge) })
    }

    func testTargetTuningMeasuresPictureSettingsAtFixedTextResolution() throws {
        let page = try scan()
        var settings = PDFSettings(dpi: 250, sourceDPI: 300, grayscale: true, ocr: false)
        settings.compression = .jpeg
        let original = try PDFExporter.estimate(pages: [page], originals: folder, settings: settings)
        let target = original * 3 / 4
        let fit = try PDFExporter.tunePictures(pages: [page], originals: folder, settings: settings,
                                               currentEstimate: original, targetBytes: target)
        XCTAssertEqual(fit.settings.compression, .adaptive)
        XCTAssertEqual(fit.settings.dpi, settings.dpi)
        XCTAssertEqual(fit.settings.grayscale, settings.grayscale)
        XCTAssertEqual(fit.settings.ocr, settings.ocr)
        XCTAssertLessThanOrEqual(fit.bytes, target)
        XCTAssertEqual(fit.bytes, try PDFExporter.estimate(pages: [page], originals: folder, settings: fit.settings))
        let underBudget = try PDFExporter.tunePictures(pages: [page], originals: folder, settings: settings,
                                                       currentEstimate: original, targetBytes: original + 1)
        XCTAssertEqual(underBudget.settings, settings)
        XCTAssertEqual(underBudget.bytes, original)
    }

    func testOCRNearThePageEdgeUsesValidPDFCoordinates() throws {
        let page = try scan()
        let encoded = try PDFExporter.page(page, originals: folder, settings: PDFSettings())
        let url = folder.appendingPathComponent("edge.pdf")
        let writer = try CleanPDFWriter(url: url)
        let edge = CGRect(x: 0.000000001, y: 0.5, width: 0.6, height: 0.05)
        try writer.add(page: encoded, text: [("Margin note", edge)])
        try writer.finish(book: BookInformation())

        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let dictionary = try XCTUnwrap(document.page(at: 1)?.dictionary)
        var stream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetStream(dictionary, "Contents", &stream))
        var format = CGPDFDataFormat.raw
        let commands = try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(stream), &format))
        let content = String(decoding: commands as Data, as: UTF8.self)
        XCTAssertNil(content.range(of: #"[0-9][eE][+-][0-9]+"#, options: .regularExpression))
        XCTAssertTrue(PDFDocument(url: url)?.string?.contains("Margin note") == true)
    }
}
