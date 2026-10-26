import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class Library: ObservableObject {
    @Published var state = LibraryState()
    @Published var preview: CGImage?
    @Published var busy = false
    @Published var status = "Import scans to begin"
    @Published var error: String?
    @Published var showOriginal = false { didSet { state.showOriginal = showOriginal; save(); refresh() } }
    @Published var croppedPreview = false { didSet { state.croppedPreview = croppedPreview; save(); refresh() } }
    @Published var grid = true { didSet { state.grid = grid; save() } }
    @Published var copied: PageEdits?
    @Published var drawingStraightenLine = false
    private var previewSource: CGImage?
    private var renderTask: Task<Void, Never>?
    private var undoEdits: [UUID: [PageEdits]] = [:]
    private let thumbnails: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    let root: URL
    var index: Int? { state.pages.firstIndex { $0.id == state.selection } }
    var page: ScanPage? { index.map { state.pages[$0] } }
    func resolvedEdits(for page: ScanPage) -> PageEdits {
        var value = page.edits
        if !page.isAdjusted {
            var settings = state.spineDefaults ?? SpineSettings()
            // Defaults share adjustment values; the checkbox belongs to each page.
            settings.enabled = page.edits.spineSettings.enabled
            value.spineSettings = settings
        }
        return value
    }
    var edits: PageEdits { page.map { resolvedEdits(for: $0) } ?? PageEdits() }
    func thumbnail(for page: ScanPage, edits: PageEdits) async -> CGImage? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(edits))?.base64EncodedString() ?? ""
        let key = (page.storedFile + encoded) as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let url = root.appendingPathComponent("Originals").appendingPathComponent(page.storedFile)
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = Imaging.load(url, maxSize: 160) else { return nil }
            return Imaging.render(source, edits: edits, crop: true)
        }.value
        guard !Task.isCancelled else { return nil }
        if let image { thumbnails.setObject(image, forKey: key, cost: image.bytesPerRow * image.height) }
        return image
    }
    func editSpine(_ settings: SpineSettings) {
        var value = edits
        value.spineSettings = settings
        edit(value)
        state.spineDefaults = settings
        save(); refresh()
    }
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scan Tidy", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root.appendingPathComponent("Originals"), withIntermediateDirectories: true)
            let file = self.root.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: file.path) { state = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: file)) }
            showOriginal = state.showOriginal ?? false
            croppedPreview = state.croppedPreview ?? false
            grid = state.grid ?? true
            if index == nil { state.selection = state.pages.first?.id }
            select(state.selection)
        } catch { self.error = "Could not open saved progress: \(error.localizedDescription)" }
    }
    func save() {
        do { try JSONEncoder().encode(state).write(to: root.appendingPathComponent("library.json"), options: .atomic) }
        catch { self.error = "Could not save progress: \(error.localizedDescription)" }
    }
    func select(_ id: UUID?) {
        drawingStraightenLine = false
        renderTask?.cancel()
        state.selection = id; save()
        previewSource = nil; preview = nil
        guard let page else { return }
        let url = root.appendingPathComponent("Originals").appendingPathComponent(page.storedFile)
        let current = page.id
        Task {
            let image = await Task.detached(priority: .userInitiated) { Imaging.load(url, maxSize: 1800) }.value
            guard self.state.selection == current else { return }
            self.previewSource = image
            if image == nil { self.error = "Could not read \(page.name)." }
            self.refresh()
        }
    }
    func refresh() {
        renderTask?.cancel()
        guard let source = previewSource else { return }
        let edits = showOriginal ? PageEdits() : self.edits
        let crop = croppedPreview && !showOriginal
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { Imaging.render(source, edits: edits, crop: crop) }.value
            guard !Task.isCancelled else { return }
            preview = result
        }
    }
    func edit(_ value: PageEdits) {
        drawingStraightenLine = false
        guard let i = index, value != edits else { return }
        let id = state.pages[i].id
        undoEdits[id, default: []].append(edits)
        if undoEdits[id, default: []].count > 100 { undoEdits[id]?.removeFirst() }
        state.pages[i].edits = value; state.pages[i].hasBeenEdited = true; state.pages[i].reviewed = false
        save(); refresh()
    }
    func undo() {
        guard let i = index, let previous = undoEdits[state.pages[i].id]?.popLast() else { return }
        state.pages[i].edits = previous; state.pages[i].reviewed = false; save(); refresh()
    }
    func next(_ offset: Int) {
        guard let i = index else { return }
        select(state.pages[min(max(i + offset, 0), state.pages.count-1)].id)
    }
    func movePages(from offsets: IndexSet, to destination: Int) {
        guard !busy, !offsets.isEmpty,
              offsets.allSatisfy({ state.pages.indices.contains($0) }),
              (0...state.pages.count).contains(destination) else { return }
        state.pages.move(fromOffsets: offsets, toOffset: destination)
        save()
        status = "Page order saved"
    }
    func deletePage() {
        guard !busy, let i = index else { return }
        let removed = state.pages.remove(at: i)
        undoEdits.removeValue(forKey: removed.id)
        let nextID = state.pages.isEmpty ? nil : state.pages[min(i, state.pages.count - 1)].id
        select(nextID)
        status = "Deleted \(removed.name) from the library"
    }
    func markNext() {
        guard let i = index else { return }
        state.pages[i].edits = edits; state.pages[i].hasBeenEdited = true
        state.pages[i].reviewed = true; save(); next(1)
    }
    func importScans() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .tiff, .heic, .bmp]
        panel.allowsMultipleSelection = true
        panel.prompt = "Import scans"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        busy = true
        Task {
            var first: UUID?
            var failures: [String] = []
            for (n, url) in urls.enumerated() {
                status = "Importing \(n+1) of \(urls.count)…"
                let id = UUID(); let filename = id.uuidString + "." + url.pathExtension
                let dest = root.appendingPathComponent("Originals").appendingPathComponent(filename)
                let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                    do {
                        guard Imaging.load(url, maxSize: 64) != nil else { return url.lastPathComponent }
                        try FileManager.default.copyItem(at: url, to: dest)
                        return nil
                    } catch { return "\(url.lastPathComponent): \(error.localizedDescription)" }
                }.value
                if let failure { failures.append(failure) } else {
                    state.pages.append(ScanPage(id: id, name: url.lastPathComponent, storedFile: filename)); first = first ?? id
                    save()
                }
            }
            if let first { select(first) }
            busy = false; status = "Imported \(urls.count-failures.count) scans · originals safely copied"
            if !failures.isEmpty { error = "Could not import:\n" + failures.joined(separator: "\n") }
        }
    }
    func autoAdjust() {
        guard let source = previewSource, let id = page?.id else { return }
        busy = true; status = "Finding page edges…"
        let edits = self.edits
        Task {
            let result = await Task.detached(priority: .userInitiated) { Imaging.autoAdjust(source, edits: edits) }.value
            if state.selection == id { edit(result.edits) }
            busy = false
            status = result.found ? "Suggested crop and angle · check the edges before marking done" : "Text straightened · adjust the blue crop edges for pale page boundaries"
        }
    }
    func resetCrop() {
        guard !busy else { return }
        var value = edits
        value.left = 0; value.right = 0; value.top = 0; value.bottom = 0
        edit(value)
    }
    func resetPage() {
        guard !busy, page != nil else { return }
        drawingStraightenLine = false
        edit(PageEdits())
    }
    func beginStraightenLine() {
        guard !busy, page != nil, preview != nil else { return }
        showOriginal = false
        croppedPreview = false
        drawingStraightenLine = true
        status = "Click the first point along a line of text · Esc to cancel"
    }
    func cancelStraightenLine() {
        guard drawingStraightenLine else { return }
        drawingStraightenLine = false
        status = "Line straightening cancelled"
    }
    @discardableResult func straightenLine(from start: CGPoint, to end: CGPoint) -> Bool {
        guard !busy, page != nil, let correction = StraightenLine.correction(from: start, to: end) else { return false }
        var value = edits
        let angle = value.angle + correction
        guard abs(angle) <= 12 else {
            status = "Choose a near-horizontal text line · fine rotation supports ±12°"
            return false
        }
        value.angle = angle
        edit(value)
        drawingStraightenLine = false
        status = "Page straightened from your line"
        return true
    }
    func resetRotation() {
        guard !busy else { return }
        var value = edits
        value.angle = 0; value.quarterTurns = 0
        edit(value)
    }
    func autoCrop() {
        guard !busy, let source = previewSource, let id = page?.id else { return }
        let current = edits
        busy = true; status = "Detecting current page edges…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { Imaging.autoCrop(source, edits: current) }.value
            if state.selection == id, result.found { edit(result.edits) }
            busy = false
            status = result.found ? "Page edges detected · review the crop before export" : "No clear page edges found · adjust the blue crop lines or edge sliders"
        }
    }
    func straightenAll() {
        busy = true
        let pages = state.pages.map { page -> ScanPage in
            var snapshot = page; snapshot.edits = resolvedEdits(for: page); return snapshot
        }
        Task {
            for (n, page) in pages.enumerated() {
                status = "Straightening \(n+1) of \(pages.count)…"
                let url = root.appendingPathComponent("Originals").appendingPathComponent(page.storedFile)
                let angle = await Task.detached(priority: .utility) { () -> Double? in
                    autoreleasepool {
                        guard let source = Imaging.load(url, maxSize: 1400) else { return nil }
                        var e = page.edits; e.angle = 0
                        guard let rotated = Imaging.render(source, edits: e, crop: false) else { return nil }
                        return Imaging.textAngle(rotated)
                    }
                }.value
                if let angle, let i = state.pages.firstIndex(where: { $0.id == page.id }) {
                    undoEdits[page.id, default: []].append(page.edits)
                    state.pages[i].edits = page.edits; state.pages[i].hasBeenEdited = true
                    state.pages[i].edits.angle = angle; state.pages[i].reviewed = false
                    save()
                }
            }
            busy = false; refresh(); status = "Straightening finished · review each page before export"
        }
    }
    func applyCopied(_ parity: Bool) {
        guard let copied, let i = index else { return }
        for n in state.pages.indices where n != i && (!parity || n % 2 == i % 2) {
            undoEdits[state.pages[n].id, default: []].append(resolvedEdits(for: state.pages[n]))
            state.pages[n].hasBeenEdited = true; state.pages[n].edits = copied; state.pages[n].reviewed = false
        }
        save(); refresh(); status = parity ? "Settings applied to matching odd/even pages" : "Settings applied to all pages"
    }
    func export() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Export here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let pages = state.pages.map { page -> ScanPage in
            var snapshot = page; snapshot.edits = resolvedEdits(for: page); return snapshot
        }; let originals = root.appendingPathComponent("Originals")
        let name = "Cleaned Scans " + DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + " " + String(UUID().uuidString.prefix(4))
        let destination = folder.appendingPathComponent(name, isDirectory: true)
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) } catch { self.error = error.localizedDescription; return }
        busy = true
        Task {
            var failures: [String] = []
            for (n, page) in pages.enumerated() {
                status = "Exporting \(n+1) of \(pages.count)…"
                let output = destination.appendingPathComponent(String(format: "%04d", n+1) + "-" + URL(fileURLWithPath: page.name).deletingPathExtension().lastPathComponent + ".png")
                let failure = await Task.detached(priority: .utility) { () -> String? in
                    autoreleasepool {
                        do {
                            guard let source = Imaging.load(originals.appendingPathComponent(page.storedFile)), let result = Imaging.render(source, edits: page.edits, crop: true) else { return page.name }
                            try Imaging.writePNG(result, to: output); return nil
                        } catch { return "\(page.name): \(error.localizedDescription)" }
                    }
                }.value
                if let failure { failures.append(failure) }
            }
            busy = false; status = "Exported \(pages.count-failures.count) full-resolution PNGs"
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            if !failures.isEmpty { error = "Some pages could not be exported:\n" + failures.joined(separator: "\n") }
        }
    }
}
