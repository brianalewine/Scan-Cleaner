import CoreGraphics
import Foundation
import ImageIO
import zlib

enum PDFImageEncoding {
    private static let jp2Identifier = "public.jpeg-2000"

    static let supportsJPEG2000 = (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(jp2Identifier) == true

    /// The caller supplies freshly rendered grayscale or RGB pixels. The encoder receives
    /// no source container, tags or metadata. Its JP2 header supplies the PDF color information.
    static func jpeg2000(_ image: CGImage, quality: Double) throws -> Data {
        guard var data = encode(image, type: jp2Identifier, properties: [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true
        ]) else {
            throw PDFExportError.message("Could not encode this image as JPEG 2000.")
        }
        try removeEncoderComments(from: &data)
        return data
    }

    /// ImageIO inserts its codec name in a JPEG 2000 COM marker even when given only pixels.
    /// Blank comment bytes in place so JP2 box lengths and tile-part offsets remain valid.
    private static func removeEncoderComments(from data: inout Data) throws {
        let valid = data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Bool in
            func word(_ offset: Int) -> Int {
                Int(UInt16(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
            }
            func long(_ offset: Int) -> Int {
                Int(UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            var box = 0
            while box <= bytes.count - 8 {
                var length = long(box)
                var header = 8
                if length == 0 {
                    length = bytes.count - box
                } else if length == 1 {
                    guard bytes.count - box >= 16 else { return false }
                    let extended = UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: box + 8, as: UInt64.self))
                    guard let size = Int(exactly: extended) else { return false }
                    length = size
                    header = 16
                }
                guard length >= header, length <= bytes.count - box else { return false }
                if long(box + 4) == 0x6a703263 { // jp2c (contiguous codestream)
                    var position = box + header
                    let end = box + length
                    guard position <= end - 2, word(position) == 0xff4f else { return false } // SOC
                    position += 2
                    var tileEnd: Int?
                    while position <= end - 2 {
                        let marker = word(position)
                        if marker == 0xffd9 { return true } // EOC
                        if marker == 0xff93 { // SOD: skip compressed packet data without interpreting it.
                            guard let next = tileEnd, next >= position + 2 else { return false }
                            position = next
                            tileEnd = nil
                            continue
                        }
                        guard marker >> 8 == 0xff, position <= end - 4 else { return false }
                        let segment = word(position + 2)
                        guard segment >= 2, segment <= end - position - 2 else { return false }
                        if marker == 0xff90 { // SOT: Psot includes the entire tile-part, beginning at SOT.
                            guard segment == 10 else { return false }
                            let size = long(position + 6)
                            guard size <= end - position else { return false }
                            tileEnd = size == 0 ? end - 2 : position + size
                        } else if marker == 0xff64 { // Preserve Lcom and Rcom, overwrite only the comment.
                            guard segment >= 4 else { return false }
                            memset(bytes.baseAddress!.advanced(by: position + 6), 0x20, segment - 4)
                        }
                        position += 2 + segment
                    }
                    return false
                }
                box += length
            }
            return false
        }
        guard valid else { throw PDFExportError.message("Could not prepare the JPEG 2000 codestream for export.") }
    }

    /// PDF FlateDecode requires the RFC 1950 wrapper, which compress2 supplies.
    static func deflate(_ data: Data) throws -> Data {
        var length = compressBound(uLong(data.count))
        var result = Data(count: Int(length))
        let status = result.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compress2(destination.bindMemory(to: UInt8.self).baseAddress, &length,
                          source.bindMemory(to: UInt8.self).baseAddress, uLong(data.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw PDFExportError.message("Could not compress the PDF stream.") }
        result.count = Int(length)
        return result
    }

    private static func encode(_ image: CGImage, type: String, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
