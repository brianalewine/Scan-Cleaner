import AppKit
import ImageIO
import Vision
import UniformTypeIdentifiers

enum PDFCompressionMode: String, Codable, CaseIterable {
    case adaptive, jpeg, jpeg2000

    var title: String {
        switch self {
        case .adaptive: return "Adaptive (text and illustrations)"
        case .jpeg: return "Whole-page JPEG"
        case .jpeg2000: return "Whole-page JPEG 2000"
        }
    }
}

struct PDFSettings: Codable, Equatable {
    var dpi = 300
    var sourceDPI = 300
    var quality = 0.85
    var grayscale = false
    var ocr = true
    var language = "en-US"
    var compression = PDFCompressionMode.adaptive
    var photoScale = 1.0
    var useScanDPI = true
    static let wholePagePaletteSizes = [32, 16, 8, 4, 2]
    static var maximumSimplification: Int { 5 + wholePagePaletteSizes.count }

    var simplification = 0
    var simplifyPictures = false
    var wholePageColorLimit: Int? {
        guard simplifyPictures, compression == .adaptive, simplification > 5 else { return nil }
        return Self.wholePagePaletteSizes[min(simplification, Self.maximumSimplification) - 6]
    }
}

extension PDFSettings {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        dpi = try values.decodeIfPresent(Int.self, forKey: .dpi) ?? dpi
        sourceDPI = try values.decodeIfPresent(Int.self, forKey: .sourceDPI) ?? sourceDPI
        quality = try values.decodeIfPresent(Double.self, forKey: .quality) ?? quality
        grayscale = try values.decodeIfPresent(Bool.self, forKey: .grayscale) ?? grayscale
        ocr = try values.decodeIfPresent(Bool.self, forKey: .ocr) ?? ocr
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? language
        // A library saved before adaptive compression used a whole-page JPEG and manual DPI.
        compression = try values.decodeIfPresent(PDFCompressionMode.self, forKey: .compression) ?? .jpeg
        simplification = min(Self.maximumSimplification, max(0, try values.decodeIfPresent(Int.self, forKey: .simplification) ?? 0))
        simplifyPictures = try values.decodeIfPresent(Bool.self, forKey: .simplifyPictures) ?? false
        photoScale = try values.decodeIfPresent(Double.self, forKey: .photoScale) ?? 1
        useScanDPI = try values.decodeIfPresent(Bool.self, forKey: .useScanDPI) ?? false
    }
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
        request.setValue("ScanCleaner/1.3 (personal book metadata lookup)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PDFExportError.message("Book lookup is unavailable. Try again or enter the details manually.") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let book = json["ISBN:\(isbn)"] as? [String: Any] else { throw PDFExportError.message("No book found for that ISBN. Enter the details manually.") }
        func names(_ key: String) -> String { (book[key] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: "; ") }
        return BookInformation(isbn: isbn, title: book["title"] as? String ?? "", author: names("authors"), publisher: names("publishers"), year: book["publish_date"] as? String ?? "")
    }
    static func lookupCatalog(_ value: String) async throws -> (subject: String, keywords: String) {
        guard let isbn = normalizedISBN(value) else { throw PDFExportError.message("Enter a valid ISBN-10 or ISBN-13, including its check digit.") }
        var components = URLComponents(string: "https://lx2.loc.gov/sru/lcdb")!
        components.queryItems = [URLQueryItem(name: "version", value: "1.1"),
            URLQueryItem(name: "operation", value: "searchRetrieve"),
            URLQueryItem(name: "query", value: "bath.isbn=\(isbn)"),
            URLQueryItem(name: "maximumRecords", value: "1"),
            URLQueryItem(name: "recordSchema", value: "marcxml")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PDFExportError.message("Library of Congress lookup is unavailable. Try again later.")
        }
        return (try subjects(from: data), try keywords(from: data))
    }
    static func keywords(from data: Data) throws -> String {
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let terms = try document.nodes(forXPath: "//*[local-name()='datafield' and @tag='653']/*[local-name()='subfield' and @code='a']")
        var keywords: [String] = []
        for term in terms {
            let value = (term.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !keywords.contains(value) { keywords.append(value) }
        }
        return keywords.joined(separator: "; ")
    }
    static func subjects(from data: Data) throws -> String {
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let diagnostics = try document.nodes(forXPath: "//*[local-name()='diagnostic']")
        guard diagnostics.isEmpty else { throw PDFExportError.message("Library of Congress could not complete this ISBN search.") }
        // MARC second indicator 0 identifies Library of Congress subject headings.
        let fields = try document.nodes(forXPath: "//*[local-name()='datafield' and (@tag='600' or @tag='610' or @tag='611' or @tag='630' or @tag='648' or @tag='650' or @tag='651') and @ind2='0']")
        var headings: [String] = []
        for field in fields {
            let parts = try field.nodes(forXPath: "*[local-name()='subfield' and not(@code='0' or @code='1' or @code='2' or @code='3' or @code='4' or @code='5' or @code='6' or @code='8')]")
            let heading = parts.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " — ")
            if !heading.isEmpty && !headings.contains(heading) { headings.append(heading) }
        }
        return headings.joined(separator: "; ")
    }
}
enum PDFExportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum PDFPixelFormat: Equatable {
    case rgb, gray, inkShades
    case indexed(Int, String, bits: Int = 8, masked: Bool = true)

    var dictionary: String {
        switch self {
        case .rgb: return "/ColorSpace /DeviceRGB /BitsPerComponent 8"
        case .gray: return "/ColorSpace /DeviceGray /BitsPerComponent 8"
        case let .indexed(last, table, bits, masked):
            return "/ColorSpace [/Indexed /DeviceRGB \(last) <\(table)>] /BitsPerComponent \(bits) \(masked ? "/Mask [0 0]" : "") /Interpolate false"
        case .inkShades: return "/ColorSpace /DeviceGray /BitsPerComponent 4"

        }
    }
}

/// rect is in top-left pixel coordinates of the page image. A picture can have fewer samples.
struct PDFImageLayer {
    let rect: CGRect
    let width: Int
    let height: Int
    let format: PDFPixelFormat
    let filter: String
    let data: Data

    var bitsPerComponent: Int {
        switch format {
        case .gray, .rgb: return 8
        case let .indexed(_, _, bits, _): return bits
        case .inkShades: return 4
        }
    }
    var grayscale: Bool {
        if case .rgb = format { return false }
        if case .indexed = format { return false }
        return true
    }
}

struct EncodedPDFPage {
    let image: CGImage
    let size: CGSize
    let layers: [PDFImageLayer]
    let summary: String

    var imageBytes: Int { layers.reduce(0) { $0 + $1.data.count } }
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
    var bytesWritten: Int64 { get throws { Int64(try handle.offset()) } }
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
    private static let hexDigits = Array("0123456789ABCDEF".utf8)
    static func hex(_ s: String, bom: Bool = false) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(2 + (bom ? 4 : 0) + 4 * s.utf16.count)
        bytes.append(0x3C)
        if bom { bytes.append(contentsOf: "FEFF".utf8) }
        for unit in s.utf16 {
            for shift in [12, 8, 4, 0] {
                bytes.append(hexDigits[Int((unit >> shift) & 15)])
            }
        }
        bytes.append(0x3E)
        return String(decoding: bytes, as: UTF8.self)
    }
    // PDF real operands use ASCII decimal notation. Vision can return coordinates close to zero.
    private static func number(_ value: CGFloat) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }
    func add(page: EncodedPDFPage, text: [(String, CGRect)]) throws {
        let pageID = nextID, contentID = nextID + 1
        nextID += 2
        pages.append(pageID)
        let size = page.size
        let sx = size.width / CGFloat(page.image.width), sy = size.height / CGFloat(page.image.height)
        var resources: [String] = []
        var content = ""
        for (index, layer) in page.layers.enumerated() {
            let imageID = nextID
            nextID += 1
            resources.append("/Im\(index) \(imageID) 0 R")
            let interpolate: String
            if case .indexed = layer.format { interpolate = "" }
            else { interpolate = layer.width < Int(layer.rect.width) ? "/Interpolate true" : "" }
            try stream(imageID, dictionary: "/Type /XObject /Subtype /Image /Width \(layer.width) /Height \(layer.height) \(layer.format.dictionary) \(interpolate) \(layer.filter)", data: layer.data)
            let rect = layer.rect
            let transform = [rect.width * sx, 0, 0, rect.height * sy, rect.minX * sx,
                             (CGFloat(page.image.height) - rect.maxY) * sy].map(Self.number).joined(separator: " ")
            let blend = layer.format == .inkShades ? "/InkBlend gs " : ""
            content += "q \(blend)\(transform) cm /Im\(index) Do Q\n"
        }
        try object(pageID, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(Self.number(size.width)) \(Self.number(size.height))] /Resources << /ExtGState << /InkBlend << /BM /Multiply >> >> /XObject << \(resources.joined(separator: " ")) >> /Font << /OCR 3 0 R >> >> /Contents \(contentID) 0 R >>")
        for (line, box) in text where !line.isEmpty {
            let height = max(1, box.height * size.height)
            let scale = box.width * size.width / (Double(max(1, line.utf16.count)) * 0.5 * height) * 100
            content += "BT /OCR \(Self.number(height)) Tf 3 Tr \(Self.number(scale)) Tz 1 0 0 1 \(Self.number(box.minX * size.width)) \(Self.number(box.minY * size.height)) Tm \(Self.hex(line)) Tj ET\n"
        }
        let commands = Data(content.utf8)
        let compressed = try PDFImageEncoding.deflate(commands)
        if compressed.count + 20 < commands.count {
            try stream(contentID, dictionary: "/Filter /FlateDecode", data: compressed)
        } else {
            try stream(contentID, dictionary: "", data: commands)
        }
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
    private static func sourceInfo(at url: URL, settings: PDFSettings) -> (dpi: Double, gray: Bool) {
        var info = (dpi: Double(max(1, settings.sourceDPI)), gray: settings.grayscale)
        guard settings.useScanDPI || settings.compression == .adaptive,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return info }
        if settings.compression == .adaptive,
           properties[kCGImagePropertyColorModel as String] as? String == kCGImagePropertyColorModelGray as String {
            info.gray = true
        }
        if settings.useScanDPI,
           let x = properties[kCGImagePropertyDPIWidth as String] as? Double,
           let y = properties[kCGImagePropertyDPIHeight as String] as? Double,
           (150...2400).contains(x), abs(x - y) <= x * 0.01 {
            info.dpi = x
        }
        return info
    }

    private static func render(_ page: ScanPage, at url: URL) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = Imaging.load(url),
              let rendered = Imaging.render(source, edits: page.edits, crop: true) else {
            throw PDFExportError.message("Could not render \(page.name).")
        }
        return rendered
    }

    static func page(_ page: ScanPage, originals: URL, settings: PDFSettings, onRaster: (CGImage) -> Void = { _ in }) throws -> EncodedPDFPage {
        let url = originals.appendingPathComponent(page.storedFile)
        let rendered = try render(page, at: url)
        return try encode(rendered, url: url, settings: settings, onRaster: onRaster)
    }

    typealias Preview = (original: CGImage, compressed: CGImage, bytes: Int, summary: String)

    static func preview(_ page: ScanPage, originals: URL, settings: PDFSettings) throws -> Preview {
        let url = originals.appendingPathComponent(page.storedFile)
        let original = try render(page, at: url)
        let encoded = try encode(original, url: url, settings: settings)
        try Task.checkCancellation()
        let decoded: CGImage
        if encoded.layers.count == 1, let layer = encoded.layers.first,
           layer.filter == "/Filter /DCTDecode", layer.width == encoded.image.width,
           layer.height == encoded.image.height,
           let source = CGImageSourceCreateWithData(layer.data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            decoded = image
        } else {
            // Render the exact PDF filters and layer placement used by the final file.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-preview-\(UUID()).pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try CleanPDFWriter(url: url)
            try writer.add(page: encoded, text: [])
            try writer.finish(book: BookInformation())
            guard let pdf = CGPDFDocument(url as CFURL), let first = pdf.page(at: 1),
                  let context = bitmap(width: encoded.image.width, height: encoded.image.height, gray: false) else {
                throw PDFExportError.message("Could not open the compressed preview.")
            }
            let bounds = CGRect(x: 0, y: 0, width: encoded.image.width, height: encoded.image.height)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(bounds)
            // The generated media box starts at zero. Render every export pixel even when
            // the requested preview is larger than the page's physical size in points.
            context.scaleBy(x: bounds.width / encoded.size.width, y: bounds.height / encoded.size.height)
            context.drawPDFPage(first)
            guard let image = context.makeImage() else { throw PDFExportError.message("Could not draw the compressed preview.") }
            decoded = image
        }
        return (original, decoded, encoded.imageBytes, encoded.summary)
    }

    private static func bitmap(width: Int, height: Int, gray: Bool) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    private static func raster(_ source: CGImage, scale: Double, gray: Bool) throws -> CGImage {
        let width = max(1, Int(Double(source.width) * scale)), height = max(1, Int(Double(source.height) * scale))
        guard let context = bitmap(width: width, height: height, gray: gray) else {
            throw PDFExportError.message("Not enough memory to prepare a page.")
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.draw(source, in: bounds)
        guard let image = context.makeImage() else { throw PDFExportError.message("Could not prepare page pixels.") }
        return image
    }

    private static func photoLayer(_ source: CGImage, rect: CGRect, scale: Double, settings: PDFSettings) throws -> PDFImageLayer {
        try Task.checkCancellation()
        let image = scale < 1 ? try raster(source, scale: scale, gray: source.colorSpace?.model == .monochrome) : source
        let data: Data
        let filter: String
        if settings.compression == .jpeg2000 {
            data = try PDFImageEncoding.jpeg2000(image, quality: settings.quality)
            filter = "/Filter /JPXDecode"
        } else {
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw PDFExportError.message("Could not create the JPEG encoder.")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: settings.quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw PDFExportError.message("Could not compress the page image.") }
            data = try stripJPEGMetadata(bytes as Data)
            filter = "/Filter /DCTDecode"
        }
        let format: PDFPixelFormat = image.colorSpace?.model == .monochrome ? .gray : .rgb
        return PDFImageLayer(rect: rect, width: image.width, height: image.height, format: format, filter: filter, data: data)
    }

    private static func encode(_ rendered: CGImage, url: URL, settings: PDFSettings, onRaster: (CGImage) -> Void = { _ in }) throws -> EncodedPDFPage {
        try Task.checkCancellation()
        let source = sourceInfo(at: url, settings: settings)
        let scale = min(1, Double(max(1, settings.dpi)) / source.dpi)
        let image = try raster(rendered, scale: scale, gray: source.gray)
        onRaster(image)
        let size = CGSize(width: Double(rendered.width) * 72 / source.dpi, height: Double(rendered.height) * 72 / source.dpi)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let photoScale = settings.compression == .adaptive ? min(1, max(0.1, settings.photoScale)) : 1
        if settings.compression == .adaptive, settings.simplification > 0 {
            let limit = settings.wholePageColorLimit
            let graphics = try PaletteCompression.encode(image, level: settings.simplification, opaque: limit != nil, colorLimit: limit)
            var layers: [PDFImageLayer] = []
            if let background = graphics.background {
                layers.append(try photoLayer(background, rect: bounds, scale: photoScale, settings: settings))
            }
            layers.append(graphics.layer)
            return EncodedPDFPage(image: image, size: size, layers: layers, summary: limit.map { "Whole page · up to \($0) colors" } ?? "Indexed color · level \(settings.simplification)")
        }
        if settings.compression == .adaptive, let split = try AdaptiveCompression.separate(image) {
            let baseScale = split.photoRects.isEmpty ? min(0.5, photoScale) : photoScale
            let background = try photoLayer(split.background, rect: bounds, scale: baseScale, settings: settings)
            let ink = PDFImageLayer(rect: bounds, width: image.width, height: image.height, format: .inkShades,
                                    filter: "/Filter /FlateDecode", data: try PDFImageEncoding.deflate(split.packed))
            let layers = [background, ink]
            let result = EncodedPDFPage(image: image, size: size, layers: layers, summary: "Smooth text and continuous-tone background")
            // A noisy mask or many small regions can cost more than keeping one full-resolution scan.
            let whole = try photoLayer(image, rect: bounds, scale: 1, settings: settings)
            if result.imageBytes + 256 * (layers.count - 1) < whole.data.count { return result }
            return EncodedPDFPage(image: image, size: size, layers: [whole], summary: "Whole-page JPEG")
        }
        let layer = try photoLayer(image, rect: bounds, scale: photoScale, settings: settings)
        return EncodedPDFPage(image: image, size: size, layers: [layer],
                              summary: settings.compression == .jpeg2000 ? "Whole-page JPEG 2000" : "Whole-page JPEG")
    }

    /// Start at the export resolution, then reduce image dimensions only as needed.
    private static func fit(_ page: EncodedPDFPage, imageBudget: Int64, settings: PDFSettings) throws -> EncodedPDFPage {
        if page.imageBytes <= imageBudget { return page }
        guard imageBudget > 0 else { throw PDFExportError.message("The size target is too small for the page text and PDF structure.") }
        let bounds = CGRect(x: 0, y: 0, width: page.image.width, height: page.image.height)
        if settings.compression == .adaptive, settings.simplification > 0 {
            // Preserve an existing full-resolution foreground by fitting only its photo layer.
            if let ink = page.layers.last, case .indexed = ink.format,
               Int64(ink.data.count + 1500) < imageBudget,
               let background = page.layers.first, page.layers.count == 2,
               let source = CGImageSourceCreateWithData(background.data as CFData, nil),
               let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                var photoSettings = settings
                photoSettings.quality = min(settings.quality, 0.4)
                for scale in [0.67, 0.5, 0.33] {
                    let photo = try photoLayer(decoded, rect: bounds, scale: scale, settings: photoSettings)
                    if Int64(photo.data.count + ink.data.count) <= imageBudget {
                        return EncodedPDFPage(image: page.image, size: page.size, layers: [photo, ink],
                                              summary: "Size-limited palette and photos")
                    }
                }
            }
            // Fully indexed pages also simplify broad graphic and photograph regions.
            // Use several colors for antialiasing and colored ink before reducing pixels.
            let smallestPalette = min(16, settings.wholePageColorLimit ?? 16)
            for count in [32, 16] where count < (settings.wholePageColorLimit ?? 33) {
                let indexed = try PaletteCompression.encode(page.image, level: 5, opaque: true, colorLimit: count)
                if indexed.layer.data.count <= imageBudget {
                    return EncodedPDFPage(image: page.image, size: page.size, layers: [indexed.layer],
                                          summary: "Size-limited indexed color")
                }
            }
            var scale = 0.88
            while true {
                let image = try raster(page.image, scale: scale, gray: settings.grayscale)
                let indexed = try PaletteCompression.encode(image, level: 5, opaque: true, colorLimit: smallestPalette)
                let layer = PDFImageLayer(rect: bounds, width: image.width, height: image.height,
                                          format: indexed.layer.format, filter: indexed.layer.filter, data: indexed.layer.data)
                if layer.data.count <= imageBudget {
                    return EncodedPDFPage(image: page.image, size: page.size, layers: [layer], summary: "Size-limited indexed color")
                }
                guard image.width > 1 || image.height > 1 else { throw PDFExportError.message("The size target is too small for this book.") }
                scale *= min(0.88, 0.94 * sqrt(Double(imageBudget) / Double(layer.data.count)))
            }
        }
        var trial = settings
        trial.compression = .jpeg
        trial.quality = min(settings.quality, 0.53)
        var scale = 1.0
        while true {
            let layer = try photoLayer(page.image, rect: bounds, scale: scale, settings: trial)
            if layer.data.count <= imageBudget {
                return EncodedPDFPage(image: page.image, size: page.size, layers: [layer], summary: "Size-limited page")
            }
            guard layer.width > 1 || layer.height > 1 else {
                throw PDFExportError.message("The size target is too small for this book.")
            }
            scale *= min(0.88, 0.94 * sqrt(Double(imageBudget) / Double(layer.data.count)))
        }
    }

    private typealias PreparedPage = (encoded: EncodedPDFPage, lines: [(String, CGRect)])
    private static func prepare(_ page: ScanPage, originals: URL, settings: PDFSettings) throws -> PreparedPage {
        // OCR and compression share an immutable raster for this page.
        var recognition: DispatchWorkItem?
        var recognizedLines: Result<[(String, CGRect)], Error> = .success([])
        defer { recognition?.wait() }
        let encoded = try self.page(page, originals: originals, settings: settings) { image in
            guard settings.ocr else { return }
            let work = DispatchWorkItem {
                recognizedLines = Result {
                    try autoreleasepool {
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.recognitionLanguages = [settings.language]
                        request.usesLanguageCorrection = true
                        try VNImageRequestHandler(cgImage: image).perform([request])
                        return (request.results ?? []).compactMap { observation in
                            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
                        }
                    }
                }
            }
            recognition = work
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
        recognition?.wait()
        recognition = nil
        let lines = try recognizedLines.get()
        try Task.checkCancellation()
        return (encoded, lines)
    }

    private static func append(_ prepared: PreparedPage, to writer: CleanPDFWriter, pagesLeft: Int,
                               settings: PDFSettings, maximumBytes: Int64?, trailerReserve: Int64) throws {
        var encoded = prepared.encoded
        let lines = prepared.lines
        if let maximumBytes {
            let remaining = maximumBytes - trailerReserve - (try writer.bytesWritten)
            let allowance = remaining / Int64(pagesLeft)
            // The writer can store the OCR stream verbatim or use its smaller compressed form.
            let pageOverhead = 5000 + lines.reduce(0) { $0 + 180 + 4 * $1.0.utf16.count }
            encoded = try fit(encoded, imageBudget: allowance - Int64(pageOverhead), settings: settings)
        }
        try writer.add(page: encoded, text: lines)
    }

    private static func reservedBytes(pageCount: Int, book: BookInformation) -> Int64 {
        Int64(4096 + pageCount * 160 + book.fields.reduce(0) { $0 + $1.1.utf16.count * 4 + 128 })
    }

    private static func finish(_ writer: CleanPDFWriter, book: BookInformation, url: URL, maximumBytes: Int64?) throws {
        try Task.checkCancellation()
        try writer.finish(book: book)
        if let maximumBytes, let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumBytes {
            throw PDFExportError.message("The finished PDF exceeds the selected size limit.")
        }
    }

    static func write(pages: [ScanPage], originals: URL, settings: PDFSettings, book: BookInformation, to url: URL, maximumBytes: Int64? = nil, progress: @escaping (Int) -> Void) throws {
        let writer = try CleanPDFWriter(url: url)
        // Reserve the final object table, page references and user-supplied metadata.
        let trailerReserve = reservedBytes(pageCount: pages.count, book: book)
        for (i, page) in pages.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let prepared = try prepare(page, originals: originals, settings: settings)
                try append(prepared, to: writer, pagesLeft: pages.count - i, settings: settings, maximumBytes: maximumBytes, trailerReserve: trailerReserve)
            }
            progress(i+1)
        }
        try finish(writer, book: book, url: url, maximumBytes: maximumBytes)
    }
    static func writeConcurrent(pages: [ScanPage], originals: URL, settings: PDFSettings, book: BookInformation, to url: URL, maximumBytes: Int64? = nil, progress: @escaping (Int) -> Void) async throws {
        let writer = try CleanPDFWriter(url: url)
        let trailerReserve = reservedBytes(pageCount: pages.count, book: book)
        // Limit both in-flight rasters and out-of-order results. A slow page cannot grow the queue.
        let capacity = ProcessInfo.processInfo.physicalMemory >= 32 * 1024 * 1024 * 1024 ? 3 : 1
        try await withThrowingTaskGroup(of: (Int, PreparedPage).self) { group in
            var ready: [Int: PreparedPage] = [:]
            var scheduled = 0, written = 0
            while written < pages.count {
                try Task.checkCancellation()
                while scheduled < min(written + capacity, pages.count) {
                    let index = scheduled
                    group.addTask {
                        try autoreleasepool {
                            (index, try prepare(pages[index], originals: originals, settings: settings))
                        }
                    }
                    scheduled += 1
                }
                if let (index, page) = try await group.next() { ready[index] = page }
                while let page = ready.removeValue(forKey: written) {
                    try Task.checkCancellation()
                    try autoreleasepool {
                        try append(page, to: writer, pagesLeft: pages.count - written, settings: settings, maximumBytes: maximumBytes, trailerReserve: trailerReserve)
                    }
                    written += 1
                    progress(written)
                }
            }
        }
        try finish(writer, book: book, url: url, maximumBytes: maximumBytes)
    }
    static func estimate(pages: [ScanPage], originals: URL, settings: PDFSettings) throws -> Int64 {
        guard !pages.isEmpty else { return 0 }
        let count = min(5, pages.count)
        let indices = count == 1 ? [0] : (0..<count).map { $0 * (pages.count-1) / (count-1) }
        var total: Int64 = 0
        for i in indices {
            try Task.checkCancellation()
            total += try autoreleasepool {
                let encoded = try page(pages[i], originals: originals, settings: settings)
                return Int64(encoded.imageBytes + encoded.layers.count * 256 + (settings.ocr ? 4000 : 450))
            }
        }
        return total / Int64(count) * Int64(pages.count) + 4096
    }

    /// Try modest picture adjustments first. Keep the best measured result if no trial fits.
    static func tunePictures(pages: [ScanPage], originals: URL, settings: PDFSettings,
                             currentEstimate: Int64, targetBytes: Int64) throws -> (settings: PDFSettings, bytes: Int64) {
        var best = (settings: settings, bytes: currentEstimate)
        guard currentEstimate > targetBytes, settings.wholePageColorLimit == nil else { return best }
        var tried = [settings]
        let maxScale = settings.compression == .adaptive ? settings.photoScale : 1
        for (scale, quality) in [(1.0, settings.quality), (1, 0.75), (0.67, 0.75), (0.5, 0.7), (0.5, 0.55)] {
            try Task.checkCancellation()
            var trial = settings
            trial.compression = .adaptive
            trial.photoScale = min(scale, maxScale)
            trial.quality = min(quality, settings.quality)
            guard !tried.contains(trial) else { continue }
            tried.append(trial)
            let bytes = try estimate(pages: pages, originals: originals, settings: trial)
            if bytes < best.bytes { best = (trial, bytes) }
            if bytes <= targetBytes { break }
        }
        return best
    }
}
