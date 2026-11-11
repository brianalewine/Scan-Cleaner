import SwiftUI
import AppKit

/// A single window-coordinate source shared by every translucent surface.
final class ScanBackdropState: ObservableObject {
    @Published private(set) var imageRect: CGRect = .zero
    private var pendingRect: CGRect = .zero
    private var scheduled = false

    func update(_ rect: CGRect) {
        pendingRect = rect
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            if self.imageRect != self.pendingRect { self.imageRect = self.pendingRect }
        }
    }
}

struct SharedScanBackdrop: NSViewRepresentable {
    @ObservedObject var state: ScanBackdropState
    let image: CGImage?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> ScanBackdropView { ScanBackdropView() }
    func updateNSView(_ view: ScanBackdropView, context: Context) {
        view.setImage(image, rect: state.imageRect, opaque: reduceTransparency)
    }
}

final class ScanBackdropView: NSView {
    private let scan = NSImageView()
    private let blur = NSVisualEffectView()
    private var windowImageRect: CGRect = .zero
    private var currentImage: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        scan.imageScaling = .scaleAxesIndependently
        addSubview(scan)
        blur.material = .sidebar
        blur.blendingMode = .withinWindow
        blur.state = .followsWindowActiveState
        addSubview(blur)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: CGImage?, rect: CGRect, opaque: Bool) {
        if currentImage !== image {
            currentImage = image
            scan.image = image.map { NSImage(cgImage: $0, size: .zero) }
        }
        windowImageRect = rect
        scan.isHidden = opaque || image == nil || rect.isEmpty
        blur.isHidden = opaque
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        // Convert once from the actual scroll view's window coordinates. No
        // independent scaling, cropping, or blur origins for separate panels.
        scan.frame = convert(windowImageRect, from: nil)
        blur.frame = bounds
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

extension View {
    @ViewBuilder
    func scanGlassButtons() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    func settingsSection() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.35)))
    }

    /// Native glass follows system contrast and transparency preferences.
    @ViewBuilder
    func scanProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    func scanGlassSurface() -> some View {
        modifier(ScanGlassSurface())
    }
}

private struct ScanGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.4)))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.2)))
        }
    }
}
