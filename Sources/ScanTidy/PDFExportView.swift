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
    @State private var worker: Task<Void, Error>?
    @State private var targetMB = 100
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
                    GroupBox("Image quality") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Button("Illustrated · recommended") { settings.dpi = 300; settings.quality = 0.85; settings.grayscale = false }
                                Button("Smaller file") { settings.dpi = 200; settings.quality = 0.75 }
                                Button("High quality") { settings.dpi = 400; settings.quality = 0.95 }
                            }
                            Picker("Original scan resolution", selection: $settings.sourceDPI) {
                                ForEach([150, 200, 300, 400, 600, 1200], id: \.self) { Text("\($0) dpi").tag($0) }
                            }
                            Text("Set this to your scanner’s resolution. It determines printed page size; 300 dpi is the initial assumption.").font(.caption).foregroundStyle(.secondary)
                            Picker("Export resolution", selection: $settings.dpi) {
                                ForEach([150, 200, 300, 400, 600], id: \.self) { Text("\($0) dpi").tag($0) }
                            }
                            Text("Images are only downsampled, never enlarged. Keep 300–400 dpi for small type and detailed illustrations.").font(.caption).foregroundStyle(.secondary)
                            HStack { Text("JPEG quality"); Slider(value: $settings.quality, in: 0.5...0.98, step: 0.01); Text("\(Int((settings.quality * 100).rounded()))%").monospacedDigit().frame(width: 45) }
                            Toggle("Grayscale (discards color)", isOn: $settings.grayscale)
                            Text("Color at 300 dpi / 85% is a starting point for illustrated books. JPEG is lossy; keep your original scans and check fine text after exporting.").font(.caption).foregroundStyle(.secondary)
                        }.padding(10)
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
                    GroupBox("Book information · optional") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                TextField("ISBN", text: $book.isbn)
                                Button(lookupBusy ? "Looking up…" : "Look Up ISBN") { lookup() }.disabled(lookupBusy || book.isbn.isEmpty)
                            }
                            Text("Lookup sends only the ISBN to Open Library. It fills empty fields; your entries take priority.").font(.caption).foregroundStyle(.secondary)
                            if !lookupMessage.isEmpty { Text(lookupMessage).font(.caption) }
                            TextField("Title", text: $book.title)
                            TextField("Author(s)", text: $book.author)
                            TextField("Publisher", text: $book.publisher)
                            TextField("Publication year / date", text: $book.year)
                            TextField("Subject", text: $book.subject)
                            TextField("Keywords", text: $book.keywords)
                            Text("Source metadata is discarded. Only the nonempty book fields above are added. No scanner information, source filenames, author account, software name, or timestamps are written into the PDF. Visible text in the scan is unchanged.").font(.caption).foregroundStyle(.secondary)
                        }.textFieldStyle(.roundedBorder).padding(10)
                    }
                    GroupBox("Expected file size") {
                        VStack(alignment: .leading, spacing: 10) {
                            if estimating { HStack { ProgressView().controlSize(.small); Text("Estimating from up to 5 evenly spaced pages…") } }
                            else if let estimatedBytes {
                                Text("About \(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .decimal))").font(.title2.bold())
                                Text("Sample-based estimate, not a limit or guarantee. Image detail and OCR can change the final size.").font(.caption).foregroundStyle(.secondary)
                                if estimatedBytes > Int64(targetMB) * 1_000_000 { Label("Above your size target. Try lower JPEG quality or resolution.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                            } else if let estimateError { Text(estimateError).foregroundStyle(.red) }
                            Picker("Size target (advisory)", selection: $targetMB) {
                                ForEach([50, 100, 200, 500, 1000, 2000], id: \.self) { Text("\($0) MB").tag($0) }
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
                    if let estimatedBytes { Text("Expected: about \(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .decimal))").fontWeight(.medium) }
                    else if estimating { Text("Estimating file size…") }
                    Text("Edits and export settings are saved.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if library.busy { Button("Cancel Export") { worker?.cancel() }.disabled(worker == nil) }
                Button("Save PDF…", systemImage: "square.and.arrow.up") { savePDF() }.scanProminentButton().disabled(library.busy || lookupBusy || !library.readyForPDF)
            }.padding(20).background(.bar)
        }
        .onAppear { settings = library.state.pdfSettings ?? PDFSettings(); book = library.state.bookInformation ?? BookInformation(); loaded = true }
        .onChange(of: settings) { _, value in if loaded { library.state.pdfSettings = value; library.save() } }
        .onChange(of: book) { _, value in if loaded { library.state.bookInformation = value; library.save() } }
        .task(id: settings) { await estimate() }
    }
    func estimate() async {
        estimatedBytes = nil; estimating = true; estimateError = nil
        let pages = pages, settings = settings, originals = library.root.appendingPathComponent("Originals")
        let task = Task.detached(priority: .utility) { try PDFExporter.estimate(pages: pages, originals: originals, settings: settings) }
        do {
            let size = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }; estimatedBytes = size; estimating = false
        } catch { guard !Task.isCancelled else { return }; estimateError = error.localizedDescription; estimating = false }
    }
    func lookup() {
        lookupBusy = true; lookupMessage = ""
        let isbn = book.isbn
        Task {
            defer { lookupBusy = false }
            do {
                let result = try await BookInformation.lookup(isbn)
                guard book.isbn == isbn else { lookupMessage = "ISBN changed; look up the new number."; return }
                if book.title.isEmpty { book.title = result.title }
                if book.author.isEmpty { book.author = result.author }
                if book.publisher.isEmpty { book.publisher = result.publisher }
                if book.year.isEmpty { book.year = result.year }
                lookupMessage = "Details from Open Library. Check the edition before exporting."
            } catch { lookupMessage = error.localizedDescription }
        }
    }
    func savePDF() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (book.title.isEmpty ? "Cleaned Book" : book.title.replacingOccurrences(of: "/", with: "-")) + ".pdf"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let pages = pages, settings = settings, book = book, originals = library.root.appendingPathComponent("Originals")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        library.busy = true; library.status = "Preparing PDF…"
        let task = Task.detached(priority: .userInitiated) {
            try PDFExporter.write(pages: pages, originals: originals, settings: settings, book: book, to: temporary) { count in
                Task { @MainActor in library.status = "Exporting PDF · \(count) of \(pages.count) pages" }
            }
        }
        worker = task
        exportTask = Task {
            defer { library.busy = false; worker = nil; try? FileManager.default.removeItem(at: temporary) }
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
