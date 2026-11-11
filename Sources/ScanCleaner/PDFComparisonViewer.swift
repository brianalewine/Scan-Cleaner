import SwiftUI
import AppKit

struct PDFComparisonViewer: NSViewRepresentable {
    let original: CGImage
    let compressed: CGImage
    let fitRequest: Int

    func makeNSView(context: Context) -> PDFComparisonView { PDFComparisonView() }

    func updateNSView(_ view: PDFComparisonView, context: Context) {
        view.update(original: original, compressed: compressed, fitRequest: fitRequest)
    }
}

/// A single owner applies both viewport transforms, avoiding asynchronous binding feedback.
final class PDFComparisonView: NSView {
    let left = PDFPreviewScrollView()
    let right = PDFPreviewScrollView()
    private var zoom: CGFloat = 1
    private var fitRequest: Int?
    private var sourceSize = CGSize.zero
    private var updating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        for scroll in [left, right] {
            scroll.documentView = PDFPreviewImageView()
            scroll.hasHorizontalScroller = true
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.drawsBackground = false
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            scroll.zoomAtCursor = { [weak self, weak scroll] factor, anchor in
                guard let self, let scroll else { return }
                self.magnify(factor: factor, anchor: anchor, from: scroll)
            }
            addSubview(scroll)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func update(original: CGImage, compressed: CGImage, fitRequest: Int) {
        (left.documentView as? PDFPreviewImageView)?.image = original
        (right.documentView as? PDFPreviewImageView)?.image = compressed
        sourceSize = CGSize(width: original.width, height: original.height)
        if self.fitRequest != fitRequest {
            self.fitRequest = fitRequest
            zoom = 1
            resizeImages(anchor: .zero, from: left, center: true)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(0, (bounds.width - 12) / 2)
        let previousSize = left.frame.size
        updating = true
        left.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        right.frame = CGRect(x: width + 12, y: 0, width: width, height: bounds.height)
        updating = false
        if previousSize != left.frame.size {
            resizeImages(anchor: CGPoint(x: width / 2, y: bounds.height / 2), from: left, center: zoom == 1)
        }
    }

    func magnify(factor: CGFloat, anchor: CGPoint, from scroll: PDFPreviewScrollView) {
        zoom = min(12, max(1, zoom * factor))
        resizeImages(anchor: anchor, from: scroll, center: false)
    }

    private func resizeImages(anchor: CGPoint, from scroll: PDFPreviewScrollView, center: Bool) {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return }
        let viewport = scroll.contentView.bounds.size
        guard viewport.width > 24, viewport.height > 24 else { return }
        let fit = min((viewport.width - 24) / sourceSize.width, (viewport.height - 24) / sourceSize.height)
        let size = CGSize(width: sourceSize.width * fit * zoom, height: sourceSize.height * fit * zoom)
        let oldSize = (scroll.documentView as? PDFPreviewImageView)?.imageSize ?? .zero
        let canvas = CursorZoomGeometry.canvas(image: size, viewport: viewport)
        let origin = center || oldSize == .zero
            ? CGPoint(x: (canvas.width - viewport.width) / 2, y: (canvas.height - viewport.height) / 2)
            : CursorZoomGeometry.origin(oldImage: oldSize, newImage: size, viewport: viewport,
                                        oldOrigin: scroll.contentView.bounds.origin, anchor: anchor)
        updating = true
        defer { updating = false }
        for target in [left, right] {
            guard let document = target.documentView as? PDFPreviewImageView else { continue }
            document.imageSize = size
            document.setFrameSize(canvas)
            document.needsDisplay = true
            target.contentView.scroll(to: origin)
            target.reflectScrolledClipView(target.contentView)
        }
    }

    @objc private func scrolled(_ notification: Notification) {
        guard !updating, let clip = notification.object as? NSClipView else { return }
        let other = clip === left.contentView ? right : left
        updating = true
        other.contentView.scroll(to: clip.bounds.origin)
        other.reflectScrolledClipView(other.contentView)
        updating = false
    }
}

final class PDFPreviewScrollView: NSScrollView {
    var zoomAtCursor: ((CGFloat, CGPoint) -> Void)?
    private func anchor(for event: NSEvent) -> CGPoint {
        let point = contentView.convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - contentView.bounds.minX, y: point.y - contentView.bounds.minY)
    }
    override func magnify(with event: NSEvent) {
        zoomAtCursor?(1 + event.magnification, anchor(for: event))
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            zoomAtCursor?(exp(event.scrollingDeltaY * 0.01), anchor(for: event))
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class PDFPreviewImageView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var imageSize = CGSize.zero
    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (bounds.width - imageSize.width) / 2,
                                      y: (bounds.height - imageSize.height) / 2,
                                      width: imageSize.width, height: imageSize.height))
    }
}
