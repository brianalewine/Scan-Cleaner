import SwiftUI
import AppKit

enum CursorZoomGeometry {
    // Extra canvas space allows an off-center page even before it fills the viewer.
    static func canvas(image: CGSize, viewport: CGSize) -> CGSize {
        CGSize(width: image.width + 2 * viewport.width, height: image.height + 2 * viewport.height)
    }

    static func origin(oldImage: CGSize, newImage: CGSize, viewport: CGSize,
                       oldOrigin: CGPoint, anchor: CGPoint) -> CGPoint {
        func offset(_ old: CGFloat, _ new: CGFloat, _ visible: CGFloat,
                    _ origin: CGFloat, _ anchor: CGFloat) -> CGFloat {
            guard old > 0 else { return 0 }
            let oldCanvas = old + 2 * visible
            let newCanvas = new + 2 * visible
            let fraction = (origin + anchor - (oldCanvas - old) / 2) / old
            return min(max(0, (newCanvas - new) / 2 + fraction * new - anchor), max(0, newCanvas - visible))
        }
        return CGPoint(x: offset(oldImage.width, newImage.width, viewport.width, oldOrigin.x, anchor.x),
                       y: offset(oldImage.height, newImage.height, viewport.height, oldOrigin.y, anchor.y))
    }
}

struct CursorZoomScrollView<Content: View>: NSViewRepresentable {
    @Binding var zoom: CGFloat
    let imageSize: CGSize
    var backdrop: ScanBackdropState? = nil
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> CursorScrollView {
        let scroll = CursorScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(scroll, selector: #selector(CursorScrollView.publishBackdrop),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.documentView = NSHostingView(rootView: AnyView(content()))
        return scroll
    }

    func updateNSView(_ scroll: CursorScrollView, context: Context) {
        scroll.backdrop = backdrop
        scroll.onMagnify = { amount in zoom = min(6, max(1, zoom * (1 + amount))) }
        guard let host = scroll.documentView as? NSHostingView<AnyView> else { return }
        let viewport = scroll.contentView.bounds.size
        let anchor = scroll.cursorAnchor()
        let origin = CursorZoomGeometry.origin(oldImage: scroll.imageSize, newImage: imageSize,
                                              viewport: viewport, oldOrigin: scroll.contentView.bounds.origin,
                                              anchor: anchor)
        let canvas = CursorZoomGeometry.canvas(image: imageSize, viewport: viewport)
        host.rootView = AnyView(content().frame(width: canvas.width, height: canvas.height))
        host.setFrameSize(canvas)
        scroll.fitted = zoom == 1
        if scroll.imageSize != imageSize {
            scroll.contentView.scroll(to: scroll.fitted || scroll.imageSize == .zero
                                      ? CGPoint(x: (canvas.width - viewport.width) / 2,
                                                y: (canvas.height - viewport.height) / 2) : origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        scroll.imageSize = imageSize
        scroll.publishBackdrop()
    }
}

final class CursorScrollView: NSScrollView {
    weak var backdrop: ScanBackdropState?
    var imageSize: CGSize = .zero

    @objc func publishBackdrop() {
        guard window != nil, let documentView, imageSize != .zero else { return }
        let rect = CGRect(x: (documentView.bounds.width - imageSize.width) / 2,
                          y: (documentView.bounds.height - imageSize.height) / 2,
                          width: imageSize.width, height: imageSize.height)
        backdrop?.update(documentView.convert(rect, to: nil))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publishBackdrop()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var fitted = true
    var onMagnify: ((CGFloat) -> Void)?
    private var lastAnchor: CGPoint?
    private var cursorTracking: NSTrackingArea?

    override func layout() {
        super.layout()
        defer { publishBackdrop() }
        guard imageSize != .zero, let documentView else { return }
        let viewport = contentView.bounds.size
        let size = CursorZoomGeometry.canvas(image: imageSize, viewport: viewport)
        if documentView.frame.size != size {
            documentView.setFrameSize(size)
            if fitted {
                contentView.scroll(to: CGPoint(x: (size.width - viewport.width) / 2,
                                              y: (size.height - viewport.height) / 2))
                reflectScrolledClipView(contentView)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        cursorTracking = tracking
    }

    override func mouseMoved(with event: NSEvent) {
        _ = cursorAnchor()
        super.mouseMoved(with: event)
    }

    func cursorAnchor() -> CGPoint {
        if let window {
            let point = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if contentView.bounds.contains(point) {
                lastAnchor = CGPoint(x: point.x - contentView.bounds.minX, y: point.y - contentView.bounds.minY)
            }
        }
        let size = contentView.bounds.size
        let point = lastAnchor ?? CGPoint(x: size.width / 2, y: size.height / 2)
        return CGPoint(x: min(size.width, max(0, point.x)), y: min(size.height, max(0, point.y)))
    }

    override func magnify(with event: NSEvent) {
        _ = cursorAnchor()
        onMagnify?(event.magnification)
    }
}
