import SwiftUI
import AppKit

struct PDFCompressionPreview: View {
    let pages: [ScanPage]
    let originals: URL
    let settings: PDFSettings
    @State private var pageIndex = 0
    @State private var fitRequest = 0
    @State private var result: PDFExporter.Preview?
    @State private var loading = true
    @State private var error: String?

    // OCR and book information do not change the visible image.
    private var request: String {
        let page = pages.indices.contains(pageIndex) ? pages[pageIndex] : nil
        return "\(page?.id.uuidString ?? "")|\(String(describing: page?.edits))|\(settings.dpi)|\(settings.sourceDPI)|\(settings.useScanDPI)|\(settings.quality)|\(settings.grayscale)|\(settings.compression.rawValue)|\(settings.photoScale)|\(settings.simplification)|\(settings.simplifyPictures)"
    }

    var body: some View {
        GroupBox("Page preview · compression comparison") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Page \(pages.isEmpty ? 0 : pageIndex + 1) of \(pages.count)").monospacedDigit()
                    Slider(value: Binding(get: { Double(pageIndex) }, set: { pageIndex = Int($0) }),
                           in: 0...Double(max(1, pages.count - 1)), step: 1)
                        .disabled(pages.count < 2).accessibilityLabel("Preview page")
                    Button("Fit both") { fitRequest += 1 }
                }
                if pages.indices.contains(pageIndex) {
                    Text(pages[pageIndex].name).font(.caption).lineLimit(1)
                }
                HStack {
                    Text("Original quality").frame(maxWidth: .infinity)
                    Text("PDF compression").frame(maxWidth: .infinity)
                }.font(.headline)
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if let result {
                        PDFComparisonViewer(original: result.original, compressed: result.compressed,
                                            fitRequest: fitRequest)
                            .opacity(loading ? 0.3 : 1)
                            .allowsHitTesting(!loading)
                    }
                    if loading {
                        ProgressView("Updating preview…")
                    } else if let error {
                        Text(error).foregroundStyle(.secondary).padding()
                    } else if result == nil {
                        Text("No pages to preview.").foregroundStyle(.secondary)
                    }
                }.frame(height: 420).clipped()
                if let result, !loading {
                    Text("\(result.summary) · \(ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .decimal)) of image data · Original \(result.original.width) × \(result.original.height) px · Preview \(result.compressed.width) × \(result.compressed.height) px")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Both views include your edits and crop. Pinch or Option-scroll over either page to zoom at the cursor; scroll to pan. Zoom and position stay matched on both sides.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        .onChange(of: pageIndex) { _, _ in result = nil; fitRequest += 1 }
        .task(id: request) { await updatePreview() }
    }

    private func updatePreview() async {
        loading = true; error = nil
        guard pages.indices.contains(pageIndex) else { loading = false; return }
        let page = pages[pageIndex], settings = settings, originals = originals
        do {
            // Avoid rendering every intermediate slider position.
            try await Task.sleep(nanoseconds: 250_000_000)
            let worker = Task.detached(priority: .userInitiated) {
                try autoreleasepool { try PDFExporter.preview(page, originals: originals, settings: settings) }
            }
            let preview = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            result = preview; loading = false
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription; result = nil; loading = false
        }
    }
}
