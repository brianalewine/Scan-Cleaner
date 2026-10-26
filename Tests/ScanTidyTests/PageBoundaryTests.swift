import XCTest
import AppKit
@testable import ScanTidy

final class PageBoundaryTests: XCTestCase {
    func testBothRealScansKeepMarginsAndExcludeUnderlyingSheets() throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (name, stackedSide) in [("01-narratives", "right"), ("02-notes", "left")] {
            let source = try XCTUnwrap(Imaging.load(workspace.appendingPathComponent("TestScans/\(name).png"), maxSize: 1800))
            let result = Imaging.autoCrop(source, edits: PageEdits())
            print("PAGE BOUNDARY \(name): \(result.edits.cropRect)")
            XCTAssertTrue(result.found)
            XCTAssertLessThan(result.edits.top, 0.04)
            XCTAssertLessThan(result.edits.bottom, 0.04)
            if stackedSide == "right" {
                XCTAssertGreaterThan(result.edits.right, 0.06)
                XCTAssertLessThan(result.edits.right, 0.10)
                XCTAssertLessThan(result.edits.left, 0.05)
            } else {
                XCTAssertGreaterThan(result.edits.left, 0.06)
                XCTAssertLessThan(result.edits.left, 0.10)
                XCTAssertLessThan(result.edits.right, 0.04)
            }
            let crop = try XCTUnwrap(Imaging.render(source, edits: result.edits, crop: true))
            try Imaging.writePNG(crop, to: workspace.appendingPathComponent("TestResults/\(name)-auto-crop.png"))
        }
    }

    func testSlantedPageEdgesAndPrintedRules() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 800, height: 1000, bitsPerComponent: 8, bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: 0.4, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
        // A visible stack extends beyond the top sheet.
        ctx.setFillColor(gray: 0.7, alpha: 1)
        ctx.fill(CGRect(x: 30, y: 20, width: 740, height: 960))
        ctx.setFillColor(gray: 0.95, alpha: 1)
        ctx.move(to: CGPoint(x: 70, y: 60))
        ctx.addLine(to: CGPoint(x: 720, y: 60))
        ctx.addLine(to: CGPoint(x: 740, y: 940))
        ctx.addLine(to: CGPoint(x: 90, y: 940))
        ctx.closePath(); ctx.fillPath()
        ctx.setFillColor(gray: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 120, y: 820, width: 570, height: 2))
        let source = try XCTUnwrap(ctx.makeImage())
        let crop = Imaging.autoCrop(source, edits: PageEdits())
        XCTAssertTrue(crop.found)
        XCTAssertEqual(crop.edits.left, 0.115, accuracy: 0.015)
        XCTAssertEqual(crop.edits.right, 0.10, accuracy: 0.015)
        XCTAssertEqual(crop.edits.top, 0.06, accuracy: 0.015)
        XCTAssertEqual(crop.edits.bottom, 0.06, accuracy: 0.015)
    }

    func testPrintedFrameOnWhitePaperIsNotAPageEdge() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 800, height: 1000, bitsPerComponent: 8, bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
        ctx.setStrokeColor(gray: 0, alpha: 1); ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: 100, y: 100, width: 600, height: 800))
        let edges = PageBoundaryDetector.detect(try XCTUnwrap(ctx.makeImage()))
        XCTAssertFalse(edges.found)
    }
}
