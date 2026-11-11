import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PDFExportView: View {
    @EnvironmentObject var library: Library
    @State private var settings = PDFSettings()
    @State private var book = BookInformation()
    @State private var estimatedBytes: Int64?
    @State private var estimating = false
    @State private var estimateError: String?
    @State private var lookupBusy = false
    @State private var lookupMessage = ""
    @State private var exportTask: Task<Void, Never>?
    @State private var exportID: UUID?
    @State private var completedPages = 0
    @State private var totalPages = 0
    @State private var timeRemaining = ""
    @State private var worker: Task<Void, Error>?
    @AppStorage("pdfSizeTargetMB") private var targetMB = 100
    @AppStorage("pdfEnforceSizeTarget") private var limitSize = false
    @State private var tuning = false
    @State private var tuningFeedback: (settings: PDFSettings, target: Int, text: String)?
    @State private var loaded = false
    var pages: [ScanPage] {
        library.state.pages.map { page in var copy = page; copy.edits = library.resolvedEdits(for: page); return copy }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back to Editing", systemImage: "chevron.left") { library.showingPDFExport = false }
                    .disabled(library.busy).keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Text("PDF Export").font(.title2.bold())
                Spacer()
                Text("\(library.state.pages.count) pages · all reviewed").foregroundStyle(.secondary)
            }.padding(20).background(.bar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GroupBox("Book information · optional") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                TextField("ISBN", text: $book.isbn)
                                Button(lookupBusy ? "Looking up…" : "Look Up ISBN") { lookup() }.disabled(lookupBusy || book.isbn.isEmpty)
                            }
                            Text("Lookup sends only the ISBN to Open Library and the Library of Congress. It fills empty fields; your entries take priority.").font(.caption).foregroundStyle(.secondary)
                            if !lookupMessage.isEmpty { Text(lookupMessage).font(.caption) }
                            TextField("Title", text: $book.title)
                            TextField("Author(s)", text: $book.author)
                            TextField("Publisher", text: $book.publisher)
                            TextField("Publication year / date", text: $book.year)
                            TextField("Subject", text: $book.subject)
                            TextField("Keywords", text: $book.keywords)
                            Text("Subjects use LCSH headings; keywords use published Library of Congress catalog terms (MARC 653), when available. Keywords are not generated.").font(.caption).foregroundStyle(.secondary)
                            Text("Source metadata is discarded. Only the nonempty book fields above are added. No scanner information, source filenames, author account, software name, or timestamps are written into the PDF. Visible text in the scan is unchanged.").font(.caption).foregroundStyle(.secondary)
                        }.textFieldStyle(.roundedBorder).padding(10)
                    }
                    GroupBox("Searchable text") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Recognize text on this Mac (OCR)", isOn: $settings.ocr)
                            Picker("Text language", selection: $settings.language) {
                                Text("English").tag("en-US"); Text("French").tag("fr-FR"); Text("German").tag("de-DE"); Text("Spanish").tag("es-ES"); Text("Italian").tag("it-IT"); Text("Portuguese").tag("pt-BR")
                            }.disabled(!settings.ocr)
                            Text("Adds invisible text for search, selection, and copying while preserving the scanned appearance. OCR can make mistakes, especially in columns and captions. This is a fixed-layout PDF, not a reflowable ebook or a fully tagged accessible PDF.").font(.caption).foregroundStyle(.secondary)
                        }.padding(10)
                    }
                    GroupBox("Image quality") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Button("Illustrated") { settings.compression = .adaptive; settings.dpi = 300; settings.photoScale = 1; settings.quality = 0.85; settings.grayscale = false }
                                Button("Smaller file") { settings.compression = .adaptive; settings.dpi = 300; settings.photoScale = 0.67; settings.quality = 0.75 }
                                Button("High quality") { settings.compression = .jpeg; settings.dpi = 400; settings.quality = 0.95 }
                            }
                            Picker("Compression", selection: $settings.compression) {
                                ForEach(PDFCompressionMode.allCases, id: \.self) { mode in
                                    Text(mode.title).tag(mode).disabled(mode == .jpeg2000 && !PDFImageEncoding.supportsJPEG2000)
                                }
                            }
                            Toggle("Read resolution from each scan", isOn: $settings.useScanDPI)
                            HStack {
                                Text(settings.useScanDPI ? "Fallback scan resolution" : "Original scan resolution")
                                Slider(value: Binding(get: { Double(settings.sourceDPI) }, set: { settings.sourceDPI = Int($0.rounded()) }), in: 150...1200, step: 1)
                                    .accessibilityLabel("Original scan resolution")
                                Text("\(settings.sourceDPI) dpi").monospacedDigit().frame(width: 75, alignment: .trailing)
                            }
                            Text(settings.useScanDPI ? "Reads the DPI stored in each image to calculate its printed page size and how many pixels to export. For example, a 600 dpi scan exported at 300 dpi uses half the pixels in each dimension. Scans without a usable DPI use the fallback setting." : "With this off, the original scan resolution above applies to every page. Turn it on to use each image’s stored DPI when calculating page size and export dimensions.").font(.caption).foregroundStyle(.secondary)
                            Picker("Export resolution", selection: $settings.dpi) {
                                ForEach([150, 200, 300, 400, 600], id: \.self) { Text("\($0) dpi").tag($0) }
                            }
                            if settings.compression == .adaptive {
                                HStack {
                                    Text("Simplification")
                                    Slider(value: Binding(get: { Double(settings.simplification) }, set: { settings.simplification = Int($0.rounded()) }), in: 0...Double(PDFSettings.maximumSimplification), step: 1)
                                        .accessibilityLabel("Simplification")
                                    Text(settings.simplification == 0 ? "Off" : "\(settings.simplification) of \(PDFSettings.maximumSimplification)").monospacedDigit().frame(width: 64)
                                }
                                if settings.simplification > 5 {
                                    Toggle("Apply palette to pictures too", isOn: $settings.simplifyPictures)
                                }
                                if let limit = settings.wholePageColorLimit {
                                    Text("Up to \(limit) colors per page at the selected export resolution. Check small print and photo shading in the preview.").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("Higher levels use fewer ink colors at the selected export resolution. Adjust the photographic background separately below.").font(.caption).foregroundStyle(.secondary)
                                    HStack {
                                        Text("Picture resolution")
                                        Slider(value: $settings.photoScale, in: 0.1...1, step: 0.01)
                                            .accessibilityLabel("Picture resolution")
                                        Text(settings.photoScale, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 45)
                                    }
                                }
                            }
                            if settings.wholePageColorLimit == nil {
                                HStack {
                                    let label = settings.compression == .adaptive ? "Picture quality" : "Image quality"
                                    Text(label)
                                    Slider(value: $settings.quality, in: 0.05...0.98, step: 0.01).accessibilityLabel(label)
                                    Text(settings.quality, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 45)
                                }
                            }
                            Toggle("Grayscale (discards color)", isOn: $settings.grayscale)
                        }.padding(10)
                    }
                    PDFCompressionPreview(pages: pages, originals: library.root.appendingPathComponent("Originals"), settings: settings)
                    GroupBox("Expected file size") {
                        VStack(alignment: .leading, spacing: 10) {
                            if estimating { HStack { ProgressView().controlSize(.small); Text("Estimating from up to 5 evenly spaced pages…") } }
                            else if let estimatedBytes {
                                Text("About \(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .decimal))").font(.title2.bold())
                                Text(limitSize ? "Starting estimate before size fitting. The saved PDF must fit the selected target." : "Sample-based estimate. Image detail and OCR can change the final size.").font(.caption).foregroundStyle(.secondary)
                            } else if let estimateError { Text(estimateError).foregroundStyle(.red) }
                            Picker("Size target", selection: $targetMB) {
                                ForEach([50, 100, 200, 500, 1000, 2000], id: \.self) { Text("\($0) MB").tag($0) }
                            }
                            Toggle("Keep saved PDF within size target", isOn: $limitSize)
                            if limitSize {
                                Text("With Simplification enabled, export keeps palette lettering first, then simplifies whole pages to fewer colors and reduces pixels as needed. Other modes use JPEG for oversized pages. OCR uses the selected export resolution. The preview shows your starting settings.").font(.caption).foregroundStyle(.secondary)
                            }
                            if !library.state.pages.isEmpty {
                                let budget = Int64(targetMB) * 1_000_000 / Int64(library.state.pages.count)
                                Text("For this book, the target allows an average of \(ByteCountFormatter.string(fromByteCount: budget, countStyle: .decimal)) per page, including searchable text.").font(.caption).foregroundStyle(.secondary)
                            }
                            if tuning {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("Testing picture settings on sampled pages…")
                                    Button("Cancel") { tuning = false }
                                }
                            } else if settings.wholePageColorLimit == nil, let estimatedBytes, estimatedBytes > Int64(targetMB) * 1_000_000 {
                                Button("Tune pictures for this target") { tuningFeedback = nil; tuning = true }
                                Text("Tries adaptive compression and progressively smaller pictures at the current text resolution.").font(.caption).foregroundStyle(.secondary)
                            }
                            if let feedback = tuningFeedback, feedback.settings == settings, feedback.target == targetMB {
                                Text(feedback.text).font(.caption)
                            }
                            Text("Upload guidance checked October 27, 2026: Z-Library users report roughly 100 MB for web uploads and up to 1 GB via FTP, with failures below those sizes. LibGen reports vary from 1–2 GB by uploader; a current official cap could not be verified. Anna’s Archive directs small collections to other libraries and does not publish a universal per-PDF cap. Verify the destination’s current rules. These are not enforced limits.").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Link("Anna’s Archive guidance", destination: URL(string: "https://annasarchive.io/datasets/upload")!)
                                Link("Z-Library user report", destination: URL(string: "https://www.reddit.com/r/zlibrary/comments/1vxmw7a/")!)
                                Link("Scan quality guidance", destination: URL(string: "https://helpx.adobe.com/acrobat/desktop/create-documents/scan-documents-to-pdfs/scanned-pdf-settings.html")!)
                            }.font(.caption)
                        }.padding(10)
                    }
                }.frame(maxWidth: 780).padding(24).frame(maxWidth: .infinity)
                .disabled(library.busy)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    if exportID != nil {
                        ProgressView(value: Double(completedPages), total: Double(max(1, totalPages)))
                            .progressViewStyle(.linear)
                            .accessibilityLabel("PDF export progress")
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                            Text("\(library.status) · \(timeRemaining)")
                                .font(.caption).monospacedDigit()
                        }
                    } else if limitSize { Text("Maximum saved size · \(targetMB) MB").fontWeight(.medium) }
                    else if let estimatedBytes { Text("Expected: about \(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .decimal))").fontWeight(.medium) }
                    else if estimating { Text("Estimating file size…") }
                    Text("Edits and export settings are saved.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if library.busy { Button("Cancel Export") { worker?.cancel() }.disabled(worker == nil) }
                Button("Save PDF…", systemImage: "square.and.arrow.up") { savePDF() }.scanProminentButton().disabled(library.busy || lookupBusy || tuning || !library.readyForPDF)
            }.padding(20).background(.bar)
        }
        .onAppear { settings = library.state.pdfSettings ?? PDFSettings(); book = library.state.bookInformation ?? BookInformation(); loaded = true }
        .onChange(of: settings) { _, value in
            tuning = false
            if loaded { library.state.pdfSettings = value; library.save() }
        }
        .onChange(of: targetMB) { _, _ in tuning = false }
        .onDisappear { tuning = false }
        .onChange(of: book) { _, value in if loaded { library.state.bookInformation = value; library.save() } }
        .task(id: settings) { await estimate() }
        .task(id: tuning) { if tuning { await tunePictures() } }
    }
    private func tunePictures() async {
        guard let currentEstimate = estimatedBytes else { tuning = false; return }
        let initial = settings, target = targetMB, pages = pages
        let budget = Int64(target) * 1_000_000
        let originals = library.root.appendingPathComponent("Originals")
        let worker = Task.detached(priority: .utility) {
            try PDFExporter.tunePictures(pages: pages, originals: originals, settings: initial,
                                        currentEstimate: currentEstimate, targetBytes: budget)
        }
        do {
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard initial == settings, target == targetMB, tuning else { return }
            settings = result.settings
            let size = ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .decimal)
            tuningFeedback = (result.settings, target, result.bytes <= budget
                ? "The sample predicts \(size) with these settings. Check the page preview before saving."
                : "The smallest estimate from these trials was \(size). Check the preview before reducing quality or export resolution further.")
            tuning = false
        } catch {
            guard !Task.isCancelled, tuning else { return }
            tuningFeedback = (initial, target, error.localizedDescription)
            tuning = false
        }
    }
    func estimate() async {
        estimatedBytes = nil; estimating = true; estimateError = nil
        let pages = pages, settings = settings, originals = library.root.appendingPathComponent("Originals")
        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            let task = Task.detached(priority: .utility) { try PDFExporter.estimate(pages: pages, originals: originals, settings: settings) }
            let size = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }; estimatedBytes = size; estimating = false
        } catch { guard !Task.isCancelled else { return }; estimateError = error.localizedDescription; estimating = false }
    }
    func lookup() {
        lookupBusy = true; lookupMessage = ""
        let isbn = book.isbn
        Task {
            defer { lookupBusy = false }
            var messages: [String] = []
            do {
                let result = try await BookInformation.lookup(isbn)
                guard book.isbn == isbn else { lookupMessage = "ISBN changed; look up the new number."; return }
                if book.title.isEmpty { book.title = result.title }
                if book.author.isEmpty { book.author = result.author }
                if book.publisher.isEmpty { book.publisher = result.publisher }
                if book.year.isEmpty { book.year = result.year }
                messages.append("Book details: Open Library.")
            } catch { messages.append("Book details: " + error.localizedDescription) }
            guard book.isbn == isbn else { lookupMessage = "ISBN changed; look up the new number."; return }
            do {
                let result = try await BookInformation.lookupCatalog(isbn)
                guard book.isbn == isbn else { lookupMessage = "ISBN changed; look up the new number."; return }
                if book.subject.isEmpty { book.subject = result.subject }
                if book.keywords.isEmpty { book.keywords = result.keywords }
                messages.append(result.subject.isEmpty ? "No LCSH subjects found." : "Subjects: Library of Congress (LCSH).")
                messages.append(result.keywords.isEmpty ? "No published catalog keywords found." : "Keywords: Library of Congress (MARC 653).")
            } catch { messages.append("Subjects and keywords: " + error.localizedDescription) }
            lookupMessage = messages.joined(separator: " ") + " Check the edition before exporting."
        }
    }
    func savePDF() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (book.title.isEmpty ? "Cleaned Book" : book.title.replacingOccurrences(of: "/", with: "-")) + ".pdf"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let pages = pages, settings = settings, book = book, originals = library.root.appendingPathComponent("Originals")
        let maximumBytes = limitSize ? Int64(targetMB) * 1_000_000 : nil
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let id = UUID()
        let start = ProcessInfo.processInfo.systemUptime
        exportID = id
        completedPages = 0
        totalPages = pages.count
        timeRemaining = "Estimating time remaining…"
        library.busy = true; library.status = "Preparing PDF…"
        let task = Task.detached(priority: .userInitiated) {
            try await PDFExporter.writeConcurrent(pages: pages, originals: originals, settings: settings, book: book, to: temporary, maximumBytes: maximumBytes) { count in
                Task { @MainActor in
                    guard exportID == id, count > completedPages else { return }
                    completedPages = count
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    let seconds = elapsed * Double(pages.count - count) / Double(count)
                    let duration = Duration.seconds(max(1, seconds.rounded()))
                    timeRemaining = count == pages.count ? "Finishing PDF…" : "About \(duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) remaining"
                    library.status = "Exporting PDF · \(count) of \(pages.count) pages"
                }
            }
        }
        worker = task
        exportTask = Task {
            defer { exportID = nil; library.busy = false; worker = nil; try? FileManager.default.removeItem(at: temporary) }
            do {
                try await task.value
                if task.isCancelled { throw CancellationError() }
                // Atomic final write leaves an existing destination untouched on render failure/cancellation.
                let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
                try data.write(to: destination, options: .atomic)
                library.status = "PDF saved · \(pages.count) pages · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .decimal))"
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch is CancellationError { library.status = "PDF export cancelled · edits preserved" }
            catch { library.error = error.localizedDescription; library.status = "PDF export failed · edits preserved" }
        }
    }
}
