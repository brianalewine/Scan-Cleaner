import Foundation

extension BookInformation {
    /// ISBN-10 and its ISBN-13 equivalent identify the same edition.
    static func canonicalISBN(_ value: String) -> String? {
        guard let isbn = normalizedISBN(value) else { return nil }
        guard isbn.count == 10 else { return isbn }
        let prefix = "978" + isbn.prefix(9)
        let sum = prefix.enumerated().reduce(0) { $0 + $1.element.wholeNumberValue! * ($1.offset % 2 == 0 ? 1 : 3) }
        return prefix + String((10 - sum % 10) % 10)
    }

    static func lookupGoogle(_ value: String) async throws -> BookInformation {
        guard let isbn = normalizedISBN(value) else { throw PDFExportError.message("Enter a valid ISBN.") }
        var url = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        url.queryItems = [URLQueryItem(name: "q", value: "isbn:\(isbn)"), URLQueryItem(name: "maxResults", value: "10")]
        var request = URLRequest(url: url.url!); request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PDFExportError.message("Google Books is unavailable.") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = parseGoogle(root, isbn: isbn) else { throw PDFExportError.message("No matching ISBN found in Google Books.") }
        return result
    }

    static func parseGoogle(_ root: [String: Any], isbn: String) -> BookInformation? {
        guard let expected = canonicalISBN(isbn) else { return nil }
        let records = root["items"] as? [[String: Any]] ?? []
        guard let info = records.compactMap({ $0["volumeInfo"] as? [String: Any] }).first(where: { info in
            (info["industryIdentifiers"] as? [[String: Any]] ?? []).contains {
                guard let id = $0["identifier"] as? String else { return false }
                return canonicalISBN(id) == expected
            }
        }) else { return nil }
        var result = BookInformation(isbn: isbn, title: info["title"] as? String ?? "",
                                     author: (info["authors"] as? [String] ?? []).joined(separator: "; "),
                                     publisher: info["publisher"] as? String ?? "")
        result.publicationDate = info["publishedDate"] as? String ?? ""
        let date = publicationComponents(result.publicationDate)
        result.year = date.year; result.publicationMonth = date.month; result.publicationDay = date.day
        result.description = plainDescription(info["description"] as? String ?? "")
        result.pageCount = (info["pageCount"] as? Int).flatMap { $0 > 0 ? String($0) : nil } ?? ""
        result.categories = (info["categories"] as? [String] ?? []).joined(separator: "; ")
        let images = info["imageLinks"] as? [String: String] ?? [:]
        result.coverURL = ["extraLarge", "large", "medium", "small", "thumbnail", "smallThumbnail"].compactMap { images[$0] }.first ?? ""
        if result.coverURL.hasPrefix("http://") { result.coverURL = "https://" + result.coverURL.dropFirst(7) }
        return result
    }

    static func plainDescription(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseCatalog(_ data: Data) throws -> BookInformation {
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        var result = BookInformation()
        result.subject = try subjects(from: data)
        result.keywords = try keywords(from: data)
        // Scope supplemental fields to the first catalog record, rather than mixing editions.
        guard let record = try document.nodes(forXPath: "//*[local-name()='record' and *[local-name()='leader']]").first else { return result }
        func values(_ predicate: String, _ codes: [String], separator: String = " ") throws -> String {
            let fields = try record.nodes(forXPath: "*[local-name()='datafield' and (\(predicate))]")
            return try fields.map { field in
                try field.nodes(forXPath: "*[local-name()='subfield' and (\(codes.map { "@code='\($0)'" }.joined(separator: " or ")))]")
                    .compactMap(\.stringValue).joined(separator: separator)
            }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        result.title = try values("@tag='245'", ["a", "b"])
        result.author = try values("@tag='100' or @tag='700'", ["a"], separator: "; ")
        let imprint = "@tag='260' or (@tag='264' and @ind2='1')"
        result.publisher = try values(imprint, ["b"])
        result.publisherCity = try values(imprint, ["a"])
        result.edition = try values("@tag='250'", ["a", "b"])
        result.publicationDate = try values(imprint, ["c"])
        let date = publicationComponents(result.publicationDate.trimmingCharacters(in: CharacterSet(charactersIn: " [].,;")))
        result.year = date.year; result.publicationMonth = date.month; result.publicationDay = date.day
        result.description = try values("@tag='520'", ["a", "b"])
        result.tableOfContents = try values("@tag='505'", ["a", "g", "t", "r"]).replacingOccurrences(of: " -- ", with: "\n")
        let extent = try values("@tag='300'", ["a"])
        if let range = extent.range(of: #"\b[0-9]+(?=\s+(?:p\.|pages\b))"#, options: .regularExpression) { result.pageCount = String(extent[range]) }
        result.categories = result.subject
        return result
    }
}
