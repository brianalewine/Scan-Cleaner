import XCTest
@testable import ScanCleaner

final class BookInformationTests: XCTestCase {
    func testEditionDetailsAndPlainTextContents() throws {
        let record: [String: Any] = [
            "title": "Example", "authors": [["name": "A. Writer"]], "publishers": ["Press"],
            "publish_places": ["New York"], "edition_name": "Second edition", "publish_date": "March 12, 2001",
            "description": ["value": "Published description\nSecond paragraph"], "number_of_pages": 321,
            "covers": [123], "subjects": [["name": "History"], ["name": "Art"]],
            "table_of_contents": [["label": "1", "title": "Introduction", "pagenum": "3"],
                                  ["title": "Background", "level": 2, "pagenum": 10]]
        ]
        let book = BookInformation.parseLookup(record, isbn: "9780140328721")
        XCTAssertEqual(book.author, "A. Writer")
        XCTAssertEqual(book.publisher, "Press")
        XCTAssertEqual(book.publisherCity, "New York")
        XCTAssertEqual(book.edition, "Second edition")
        XCTAssertEqual(book.year, "2001")
        XCTAssertEqual(book.publicationMonth, "3")
        XCTAssertEqual(book.publicationDay, "12")
        XCTAssertEqual(book.coverURL, "https://covers.openlibrary.org/b/id/123-L.jpg")
        XCTAssertEqual(book.description, "Published description\nSecond paragraph")
        XCTAssertEqual(book.tableOfContents, "1 Introduction — 3\n  Background — 10")
        XCTAssertEqual(book.pageCount, "321")
        XCTAssertEqual(book.categories, "History; Art")
        XCTAssertEqual(try JSONDecoder().decode(BookInformation.self, from: JSONEncoder().encode(book)), book)
    }
    func testPartialDatesDoNotInventMonthOrDay() {
        let year = BookInformation.publicationComponents("2001")
        XCTAssertEqual(year.year, "2001"); XCTAssertEqual(year.month, ""); XCTAssertEqual(year.day, "")
        let month = BookInformation.publicationComponents("March 2001")
        XCTAssertEqual(month.year, "2001"); XCTAssertEqual(month.month, "3"); XCTAssertEqual(month.day, "")
        let unknown = BookInformation.publicationComponents("circa 2001")
        XCTAssertEqual(unknown.year, ""); XCTAssertEqual(unknown.month, ""); XCTAssertEqual(unknown.day, "")
    }
    func testLegacyBookAndMergePreserveUserEntries() throws {
        var book = try JSONDecoder().decode(BookInformation.self, from: Data(#"{"title":"My title","year":"1990","author":"My author"}"#.utf8))
        XCTAssertEqual(book.description, "")
        book.fillEmptyFields(from: BookInformation.parseLookup(["title": "Other", "publishers": ["Press"], "publish_date": "2001"], isbn: "9780140328721"))
        XCTAssertEqual(book.title, "My title"); XCTAssertEqual(book.year, "1990")
        XCTAssertEqual(book.publisher, "Press")
    }
    func testGoogleRequiresExactOrEquivalentISBN() throws {
        let wrong: [String: Any] = ["volumeInfo": ["title": "Wrong edition", "industryIdentifiers": [["identifier": "9780804429573"]]]]
        let right: [String: Any] = ["volumeInfo": ["title": "Right edition", "industryIdentifiers": [["identifier": "0140328726"]],
            "authors": ["Writer"], "publishedDate": "2001-03-12", "description": "<p>First &amp; second</p><p>Next</p>",
            "pageCount": 123, "categories": ["History"], "imageLinks": ["thumbnail": "http://example.org/cover.jpg"]]]
        let book = try XCTUnwrap(BookInformation.parseGoogle(["items": [wrong, right]], isbn: "9780140328721"))
        XCTAssertEqual(book.title, "Right edition")
        XCTAssertEqual(book.author, "Writer")
        XCTAssertEqual(book.description, "First & second\nNext")
        XCTAssertEqual(book.publicationDay, "12")
        XCTAssertEqual(book.pageCount, "123")
        XCTAssertEqual(book.coverURL, "https://example.org/cover.jpg")
        XCTAssertNil(BookInformation.parseGoogle(["items": [wrong]], isbn: "9780140328721"))
    }
    func testCatalogSupplementalDetails() throws {
        let xml = #"<collection xmlns="http://www.loc.gov/MARC21/slim"><record><leader>test</leader><datafield tag="264" ind2="1"><subfield code="a">New York :</subfield><subfield code="b">Example Press,</subfield><subfield code="c">2001.</subfield></datafield><datafield tag="250"><subfield code="a">2nd ed.</subfield></datafield><datafield tag="520"><subfield code="a">Published summary.</subfield></datafield><datafield tag="505"><subfield code="a">Introduction -- Chapter one -- Chapter two</subfield></datafield><datafield tag="300"><subfield code="a">xii, 234 pages</subfield></datafield><datafield tag="650" ind2="0"><subfield code="a">History</subfield></datafield></record></collection>"#
        let book = try BookInformation.parseCatalog(Data(xml.utf8))
        XCTAssertEqual(book.publisherCity, "New York :")
        XCTAssertEqual(book.publisher, "Example Press,")
        XCTAssertEqual(book.year, "2001")
        XCTAssertEqual(book.edition, "2nd ed.")
        XCTAssertEqual(book.description, "Published summary.")
        XCTAssertEqual(book.tableOfContents, "Introduction\nChapter one\nChapter two")
        XCTAssertEqual(book.pageCount, "234")
        XCTAssertEqual(book.categories, "History")
    }

}
