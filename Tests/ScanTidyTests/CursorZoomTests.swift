import XCTest
import AppKit
@testable import ScanTidy

final class CursorZoomTests: XCTestCase {
    @MainActor func testSharedBackdropFollowsPanAndZoomInWindowCoordinates() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        window.contentView = root
        let scroll = CursorScrollView(frame: NSRect(x: 220, y: 60, width: 500, height: 600))
        root.addSubview(scroll)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 2000, height: 2600))
        scroll.documentView = document
        let state = ScanBackdropState()
        scroll.backdrop = state
        scroll.imageSize = CGSize(width: 1000, height: 1400)
        scroll.fitted = false
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: CGPoint(x: 300, y: 400))
        scroll.publishBackdrop()
        try await Task.sleep(nanoseconds: 10_000_000)
        let first = state.imageRect
        XCTAssertEqual(first.size, scroll.imageSize)

        scroll.contentView.scroll(to: CGPoint(x: 380, y: 450))
        scroll.publishBackdrop()
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(state.imageRect.minX, first.minX - 80, accuracy: 0.01)
        XCTAssertEqual(state.imageRect.minY, first.minY - 50, accuracy: 0.01)

        scroll.imageSize = CGSize(width: 2000, height: 2800)
        scroll.needsLayout = true
        scroll.layoutSubtreeIfNeeded()
        scroll.publishBackdrop()
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(state.imageRect.size, scroll.imageSize)
        // Every panel converts this same window rectangle, without a local fit.
        let panel = NSView(frame: NSRect(x: 750, y: 0, width: 250, height: 800))
        root.addSubview(panel)
        let local = panel.convert(state.imageRect, from: nil)
        XCTAssertEqual(panel.convert(local, to: nil), state.imageRect)
    }

    func testZoomFromFitKeepsPagePointUnderCursor() {
        let origin = CursorZoomGeometry.origin(oldImage: CGSize(width: 400, height: 600),
                                               newImage: CGSize(width: 1200, height: 1800),
                                               viewport: CGSize(width: 800, height: 700),
                                               oldOrigin: CGPoint(x: 600, y: 650), anchor: CGPoint(x: 450, y: 250))
        XCTAssertEqual(origin.x, 1100, accuracy: 0.001)
        XCTAssertEqual(origin.y, 1050, accuracy: 0.001)
    }

    func testFirstZoomStepAnchorsBeforePageFillsWidth() {
        let origin = CursorZoomGeometry.origin(oldImage: CGSize(width: 400, height: 600),
                                              newImage: CGSize(width: 500, height: 750),
                                              viewport: CGSize(width: 800, height: 700),
                                              oldOrigin: CGPoint(x: 600, y: 650),
                                              anchor: CGPoint(x: 500, y: 250))
        XCTAssertEqual(origin.x, 675, accuracy: 0.001)
        XCTAssertEqual(origin.y, 700, accuracy: 0.001)
        // The same point (75% across the page) stays at x=500 in the viewport.
        XCTAssertEqual(800 + 0.75 * 500 - origin.x, 500, accuracy: 0.001)
    }

    func testZoomAfterPanningKeepsCursorAnchorAndReverses() {
        let viewport = CGSize(width: 800, height: 700)
        let small = CGSize(width: 1200, height: 1800)
        let large = CGSize(width: 2400, height: 3600)
        let anchor = CGPoint(x: 550, y: 180)
        let start = CGPoint(x: 250, y: 600)
        let zoomed = CursorZoomGeometry.origin(oldImage: small, newImage: large, viewport: viewport,
                                              oldOrigin: start, anchor: anchor)
        let restored = CursorZoomGeometry.origin(oldImage: large, newImage: small, viewport: viewport,
                                                oldOrigin: zoomed, anchor: anchor)
        XCTAssertEqual(restored.x, start.x, accuracy: 0.001)
        XCTAssertEqual(restored.y, start.y, accuracy: 0.001)
    }
}
