import AppKit
import ImageIO
import Vision
import UniformTypeIdentifiers

struct PDFSettings: Codable, Equatable {
    var dpi = 300
    var sourceDPI = 300
    var quality = 0.85
    var grayscale = false
    var ocr = true
    var language = "en-US"
}
struct BookInformation: Codable, Equatable {
    var isbn = ""
    var title = ""
    var author = ""
    var publisher = ""
    var year = ""
    var subject = ""
    var keywords = ""
    var fields: [(String, String)] {
        [("Title", title), ("Author", author), ("Publisher", publisher), ("PublicationDate", year),
         ("ISBN", isbn), ("Subject", subject), ("Keywords", keywords)].filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    static func normalizedISBN(_ value: String) -> String? {
        let s = value.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "").uppercased()
        let chars = Array(s)
        if chars.count == 13, chars.allSatisfy({ $0.isNumber && $0.isASCII }) {
            let sum = chars.enumerated().reduce(0) { $0 + $1.element.wholeNumberValue! * ($1.offset % 2 == 0 ? 1 : 3) }
            return sum % 10 == 0 ? s : nil
        }
        if chars.count == 10 {
            var sum = 0
            for (i, c) in chars.enumerated() {
                guard let n = c.isASCII ? c.wholeNumberValue : nil else {
                    if i == 9 && c == "X" { sum += 10; continue }; return nil
                }
                sum += n * (10-i)
            }
            return sum % 11 == 0 ? s : nil
        }
        return nil
    }
    static func lookup(_ isbn: String) async throws -> BookInformation {
        guard let isbn = normalizedISBN(isbn) else { throw PDFExportError.message("Enter a valid ISBN-10 or ISBN-13, including its check digit.") }
        let url = URL(string: "https://openlibrary.org/api/books?bibkeys=ISBN:\(isbn)&format=json&jscmd=data")!
        var request = URLRequest(url: url); request.timeoutInterval = 30
        request.setValue("ScanTidy/1.3 (personal book metadata lookup)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PDFExportError.message("Book lookup is unavailable. Try again or enter the details manually.") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let book = json["ISBN:\(isbn)"] as? [String: Any] else { throw PDFExportError.message("No book found for that ISBN. Enter the details manually.") }
        func names(_ key: String) -> String { (book[key] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: "; ") }
        return BookInformation(isbn: isbn, title: book["title"] as? String ?? "", author: names("authors"), publisher: names("publishers"), year: book["publish_date"] as? String ?? "")
    }
}
enum PDFExportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// Writes a new, minimal PDF, never importing source containers or metadata dictionaries.
/// The only descriptive metadata is the explicitly supplied book information.
final class CleanPDFWriter {
    private let handle: FileHandle
    private var offsets: [UInt64] = [0]
    private var pages: [Int] = []
    private var nextID = 7
    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw PDFExportError.message("Could not create temporary PDF.") }
        handle = try FileHandle(forWritingTo: url)
        try write("%PDF-1.7\n")
        try object(1, "<< /Type /Catalog /Pages 2 0 R >>")
        // Invisible OCR uses Unicode CIDs and an explicit extraction map; no source fonts are copied.
        try object(3, "<< /Type /Font /Subtype /Type0 /BaseFont /Helvetica /Encoding /Identity-H /DescendantFonts [4 0 R] /ToUnicode 5 0 R >>")
        try object(4, "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /DW 500 /FontDescriptor 6 0 R /CIDToGIDMap /Identity >>")
        try object(6, "<< /Type /FontDescriptor /FontName /Helvetica /Flags 32 /FontBBox [0 -250 1000 1000] /ItalicAngle 0 /Ascent 1000 /Descent -250 /CapHeight 750 /StemV 80 >>")
        let cmap = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Unicode def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n1 beginbfrange\n<0000> <FFFF> <0000>\nendbfrange\nendcmap\nCMapName currentdict /CMap defineresource pop\nend end"
        try stream(5, dictionary: "", data: Data(cmap.utf8))
    }
    deinit { try? handle.close() }
    private func write(_ s: String) throws { try handle.write(contentsOf: Data(s.utf8)) }
    private func start(_ id: Int) throws {
        while offsets.count <= id { offsets.append(0) }
        offsets[id] = try handle.offset()
        try write("\(id) 0 obj\n")
    }
    private func object(_ id: Int, _ s: String) throws { try start(id); try write(s + "\nendobj\n") }
    private func stream(_ id: Int, dictionary: String, data: Data) throws {
        try start(id); try write("<< \(dictionary) /Length \(data.count) >>\nstream\n")
        try handle.write(contentsOf: data); try write("\nendstream\nendobj\n")
    }
    static func hex(_ s: String, bom: Bool = false) -> String {
        "<" + (bom ? "FEFF" : "") + s.utf16.map { String(format: "%04X", $0) }.joined() + ">"
    }
    func add(image: CGImage, jpeg: Data, size: CGSize, text: [(String, CGRect)], grayscale: Bool) throws {
        let pageID = nextID, imageID = nextID + 1, contentID = nextID + 2; nextID += 3
        pages.append(pageID)
        try object(pageID, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(size.width) \(size.height)] /Resources << /XObject << /Scan \(imageID) 0 R >> /Font << /OCR 3 0 R >> >> /Contents \(contentID) 0 R >>")
        try stream(imageID, dictionary: "/Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) /ColorSpace /\(grayscale ? "DeviceGray" : "DeviceRGB") /BitsPerComponent 8 /Filter /DCTDecode", data: jpeg)
        var content = "q \(size.width) 0 0 \(size.height) 0 0 cm /Scan Do Q\n"
        for (line, box) in text where !line.isEmpty {
            let height = max(1, box.height * size.height)
            let scale = box.width * size.width / (Double(max(1, line.utf16.count)) * 0.5 * height) * 100
            content += "BT /OCR \(height) Tf 3 Tr \(scale) Tz 1 0 0 1 \(box.minX * size.width) \(box.minY * size.height) Tm \(Self.hex(line)) Tj ET\n"
        }
        try stream(contentID, dictionary: "", data: Data(content.utf8))
    }
    func finish(book: BookInformation) throws {
        try object(2, "<< /Type /Pages /Count \(pages.count) /Kids [\(pages.map { "\($0) 0 R" }.joined(separator: " "))] >>")
        let infoID = nextID
        try object(infoID, "<< " + book.fields.map { "/\($0.0) \(Self.hex($0.1, bom: true))" }.joined(separator: " ") + " >>")
        let xref = try handle.offset()
        try write("xref\n0 \(offsets.count)\n0000000000 65535 f \n")
        for offset in offsets.dropFirst() { try write(String(format: "%010llu 00000 n \n", offset)) }
        try write("trailer\n<< /Size \(offsets.count) /Root 1 0 R /Info \(infoID) 0 R >>\nstartxref\n\(xref)\n%%EOF\n")
        try handle.synchronize(); try handle.close()
    }
}

enum PDFExporter {
    // ImageIO adds fresh EXIF dimensions even without source properties. Remove all
    // application/comment segments too, leaving only the JPEG coding structure.
    static func stripJPEGMetadata(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { throw PDFExportError.message("Invalid JPEG encoding.") }
        var result = Data(bytes[0..<2]), index = 2
        while index < bytes.count {
            let start = index
            guard bytes[index] == 0xff else { throw PDFExportError.message("Invalid JPEG marker.") }
            while index < bytes.count && bytes[index] == 0xff { index += 1 }
            guard index < bytes.count else { throw PDFExportError.message("Incomplete JPEG marker.") }
            let marker = bytes[index]; index += 1
            if marker == 0xda || marker == 0xd9 { result.append(contentsOf: bytes[start...]); return result }
            guard index + 1 < bytes.count else { throw PDFExportError.message("Incomplete JPEG segment.") }
            let length = Int(bytes[index]) * 256 + Int(bytes[index + 1])
            guard length >= 2, index + length <= bytes.count else { throw PDFExportError.message("Invalid JPEG segment length.") }
            if !(0xe0...0xef).contains(marker) && marker != 0xfe { result.append(contentsOf: bytes[start..<(index + length)]) }
            index += length
        }
        throw PDFExportError.message("JPEG image data is missing.")
    }
    static func page(_ page: ScanPage, originals: URL, settings: PDFSettings) throws -> (CGImage, Data, CGSize) {
        guard let source = Imaging.load(originals.appendingPathComponent(page.storedFile)),
              let rendered = Imaging.render(source, edits: page.edits, crop: true) else { throw PDFExportError.message("Could not render \(page.name). No PDF was saved.") }
        let scale = min(1, Double(settings.dpi) / Double(max(1, settings.sourceDPI)))
        let w = max(1, Int(Double(rendered.width) * scale)), h = max(1, Int(Double(rendered.height) * scale))
        let gray = settings.grayscale
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue) else { throw PDFExportError.message("Not enough memory to prepare a page.") }
        context.interpolationQuality = .high
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = context.makeImage() else { throw PDFExportError.message("Could not prepare page pixels.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw PDFExportError.message("Could not encode page.") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: settings.quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PDFExportError.message("Could not compress page.") }
        return (image, try stripJPEGMetadata(data as Data), CGSize(width: Double(rendered.width) * 72 / Double(settings.sourceDPI), height: Double(rendered.height) * 72 / Double(settings.sourceDPI)))
    }
    static func write(pages: [ScanPage], originals: URL, settings: PDFSettings, book: BookInformation, to url: URL, progress: @escaping (Int) -> Void) throws {
        let writer = try CleanPDFWriter(url: url)
        for (i, page) in pages.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let (image, jpeg, size) = try self.page(page, originals: originals, settings: settings)
                var lines: [(String, CGRect)] = []
                if settings.ocr {
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                    request.recognitionLanguages = [settings.language]; request.usesLanguageCorrection = true
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    lines = (request.results ?? []).compactMap { observation in
                        observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
                    }
                }
                try writer.add(image: image, jpeg: jpeg, size: size, text: lines, grayscale: settings.grayscale)
            }
            progress(i+1)
        }
        try Task.checkCancellation()
        try writer.finish(book: book)
    }
    static func estimate(pages: [ScanPage], originals: URL, settings: PDFSettings) throws -> Int64 {
        guard !pages.isEmpty else { return 0 }
        let count = min(5, pages.count)
        let indices = count == 1 ? [0] : (0..<count).map { $0 * (pages.count-1) / (count-1) }
        var total: Int64 = 0
        for i in indices {
            try Task.checkCancellation()
            total += try autoreleasepool { Int64(try page(pages[i], originals: originals, settings: settings).1.count) + (settings.ocr ? 16000 : 1000) }
        }
        return total / Int64(count) * Int64(pages.count) + 4096
    }
}
