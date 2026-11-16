import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class Library: ObservableObject {
    @Published var state = LibraryState()
    @Published private(set) var selectedPageIDs: Set<UUID> = []
    var hasMultipleSelection: Bool { selectedPageIDs.count > 1 }
    @Published var showingPDFExport = false
    var readyForPDF: Bool { !state.pages.isEmpty && state.pages.allSatisfy(\.reviewed) }
    @Published var preview: CGImage?
    @Published private(set) var batchRunning = false
    private var batchTask: Task<Void, Never>?
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
    private var previewRevision = 0
    private var saveTask: Task<Void, Never>?
    private enum UndoAction {
        case batch([ScanPage])
        case spineDefaults([ScanPage], SpineSettings?)
    }
    private var undoActions: [UndoAction] = []
    private var redoActions: [UndoAction] = []
    private var sliderSnapshot: ScanPage?
    private func remember(_ action: UndoAction) {
        guard sliderSnapshot == nil else { return }
        redoActions.removeAll()
        undoActions.append(action)
        if undoActions.count > 100 { undoActions.removeFirst() }
    }
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
            settings.side = page.edits.spineSettings.side
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
    }
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scan Cleaner", isDirectory: true)
        do {
            if root == nil {
                try Self.migrateLibrary(in: self.root.deletingLastPathComponent())
            }
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
    /// The former folder name is retained only to locate existing user data.
    static func migrateLibrary(in support: URL) throws {
        let legacy = support.appendingPathComponent("Scan Tidy", isDirectory: true)
        let destination = support.appendingPathComponent("Scan Cleaner", isDirectory: true)
        let manager = FileManager.default
        if manager.fileExists(atPath: legacy.path) && !manager.fileExists(atPath: destination.path) {
            try manager.moveItem(at: legacy, to: destination)
        }
    }

    func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }
    func save() {
        saveTask?.cancel()
        saveTask = nil
        do { try JSONEncoder().encode(state).write(to: root.appendingPathComponent("library.json"), options: .atomic) }
        catch { self.error = "Could not save progress: \(error.localizedDescription)" }
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return }
            self?.save()
        }
    }
    func selectPages(_ ids: Set<UUID>) {
        let valid = ids.intersection(state.pages.map(\.id))
        let primary = state.selection.flatMap { valid.contains($0) ? $0 : nil }
            ?? state.pages.first(where: { valid.contains($0.id) })?.id
        if primary != state.selection { select(primary) }
        selectedPageIDs = valid
        if hasMultipleSelection { drawingStraightenLine = false }
    }
    func select(_ id: UUID?) {
        endSliderEdit()
        selectedPageIDs = Set(id.map { [$0] } ?? [])
        drawingStraightenLine = false
        renderTask?.cancel()
        renderTask = nil
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
        previewRevision += 1
        guard previewSource != nil, renderTask == nil else { return }
        renderTask = Task {
            // Keep one render in flight. New edits replace pending work instead of
            // cancelling every frame and waiting for the user to stop dragging.
            while !Task.isCancelled, let source = previewSource {
                let revision = previewRevision
                let edits = showOriginal ? PageEdits() : self.edits
                let crop = croppedPreview && !showOriginal
                let result = await Task.detached(priority: .userInitiated) {
                    autoreleasepool { Imaging.render(source, edits: edits, crop: crop) }
                }.value
                guard !Task.isCancelled else { return }
                preview = result
                if revision == previewRevision { break }
            }
            renderTask = nil
        }
    }
    func edit(_ value: PageEdits) {
        drawingStraightenLine = false
        guard !hasMultipleSelection, let i = index, value != edits else { return }
        remember(.batch([state.pages[i]]))
        state.pages[i].edits = value; state.pages[i].hasBeenEdited = true; state.pages[i].reviewed = false
        scheduleSave(); refresh()
    }
    func beginSliderEdit() {
        guard sliderSnapshot == nil, let page else { return }
        sliderSnapshot = page
    }
    func endSliderEdit() {
        guard let snapshot = sliderSnapshot else { return }
        sliderSnapshot = nil
        guard let current = state.pages.first(where: { $0.id == snapshot.id }),
              current.edits != snapshot.edits else { return }
        remember(.batch([snapshot]))
    }
    func setDefaultSpineShadow() {
        guard !busy, page != nil else { return }
        endSliderEdit()
        let settings = edits.spineSettings
        let snapshots = state.pages.filter { !$0.reviewed }
        remember(.spineDefaults(snapshots, state.spineDefaults))
        var defaults = state.spineDefaults ?? SpineSettings()
        defaults.width = settings.width
        defaults.strength = settings.strength
        for i in state.pages.indices where !state.pages[i].reviewed {
            var value = resolvedEdits(for: state.pages[i])
            var spine = value.spineSettings
            spine.width = settings.width
            spine.strength = settings.strength
            value.spineSettings = spine
            state.pages[i].edits = value
        }
        state.spineDefaults = defaults
        save(); refresh()
        status = "Default spine width and strength applied to unfinished pages"
    }
    private func restore(_ action: UndoAction) -> UndoAction {
        switch action {
        case .batch(let snapshots), .spineDefaults(let snapshots, _):
            let ids = Set(snapshots.map(\.id))
            let inverse = state.pages.filter { ids.contains($0.id) }
            let defaults = state.spineDefaults
            for snapshot in snapshots {
                guard let i = state.pages.firstIndex(where: { $0.id == snapshot.id }) else { continue }
                state.pages[i].edits = snapshot.edits
                state.pages[i].reviewed = snapshot.reviewed
                state.pages[i].hasBeenEdited = snapshot.hasBeenEdited
            }
            if case .spineDefaults(_, let previous) = action {
                state.spineDefaults = previous
                return .spineDefaults(inverse, defaults)
            }
            return .batch(inverse)
        }
    }
    func undo() {
        guard !busy else { return }
        endSliderEdit()
        guard let action = undoActions.popLast() else { return }
        redoActions.append(restore(action))
        save(); refresh()
    }
    func redo() {
        guard !busy else { return }
        endSliderEdit()
        guard let action = redoActions.popLast() else { return }
        undoActions.append(restore(action))
        save(); refresh()
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
    func moveSelectedPages(by direction: Int) {
        guard !busy, direction == -1 || direction == 1 else { return }
        let indices = state.pages.indices.filter { selectedPageIDs.contains(state.pages[$0].id) }
        guard let first = indices.first, let last = indices.last,
              direction < 0 ? first > 0 : last < state.pages.count - 1 else { return }
        // Traverse toward the movement direction so each selected run moves one row.
        for i in direction < 0 ? indices : indices.reversed() {
            state.pages.swapAt(i, i + direction)
        }
        save()
        status = "Page order saved"
    }
    func deletePage() {
        guard !busy, let first = state.pages.firstIndex(where: { selectedPageIDs.contains($0.id) }) else { return }
        let removed = state.pages.filter { selectedPageIDs.contains($0.id) }
        let removedIDs = Set(removed.map(\.id))
        state.pages.removeAll { removedIDs.contains($0.id) }
        redoActions.removeAll()
        undoActions.removeAll { action in
            switch action {
            case .batch(let pages): return pages.allSatisfy { removedIDs.contains($0.id) }
            case .spineDefaults: return false
            }
        }
        let nextID = state.pages.isEmpty ? nil : state.pages[min(first, state.pages.count - 1)].id
        select(nextID)
        status = removed.count == 1 ? "Deleted \(removed[0].name) from the library" : "Deleted \(removed.count) pages from the library"
    }
    func markNext() {
        guard !busy, !hasMultipleSelection, let i = index else { return }
        state.pages[i].edits = edits; state.pages[i].hasBeenEdited = true
        state.pages[i].reviewed = true
        save()
        if i + 1 < state.pages.count {
            select(state.pages[i + 1].id)
            status = "Page \(i + 1) marked done · now on page \(i + 2)"
        } else {
            drawingStraightenLine = false
            status = "Page \(i + 1) marked done · last page reached"
        }
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
    func resetCrop() {
        guard !busy else { return }
        var value = edits
        value.left = 0; value.right = 0; value.top = 0; value.bottom = 0
        edit(value)
        save()
    }
    func resetPage() {
        guard !busy, page != nil else { return }
        drawingStraightenLine = false
        edit(PageEdits())
        save()
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
        save()
    }
    func autoCrop() {
        guard !busy, let source = previewSource, let id = page?.id else { return }
        let current = edits
        busy = true; status = "Detecting current page edges…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { Imaging.autoCrop(source, edits: current) }.value
            if state.selection == id, result.found { edit(result.edits) }
            busy = false
            status = result.found ? "Page edges detected · review the crop before export" : "No clear page edges found · adjust the crop lines or edge sliders"
        }
    }
    func straightenPage() {
        guard !busy, let page else { return }
        drawingStraightenLine = false
        let current = edits
        let url = root.appendingPathComponent("Originals").appendingPathComponent(page.storedFile)
        busy = true; status = "Straightening this page…"
        Task {
            let adjusted = await Task.detached(priority: .userInitiated) { () -> PageEdits? in
                autoreleasepool {
                    guard let source = Imaging.load(url, maxSize: 1400) else { return nil }
                    var base = current; base.angle = 0
                    guard let rotated = Imaging.render(source, edits: base, crop: false) else { return nil }
                    base.angle = Imaging.textAngle(rotated)
                    return Imaging.cropRotationBorders(source, edits: base)
                }
            }.value
            if let adjusted {
                if state.selection == page.id {
                    edit(adjusted)
                    save()
                    status = "Page straightened · review the angle before marking done"
                }
            } else {
                error = "Could not read \(page.name) for straightening."
                status = "Could not straighten this page"
            }
            busy = false
        }
    }
    func stopStraightenAndCrop() {
        guard batchRunning else { return }
        batchTask?.cancel()
        status = "Stopping straighten and crop…"
    }
    func cancelCurrentOperation() {
        if batchRunning { stopStraightenAndCrop() }
        else { cancelStraightenLine() }
    }
    func straightenAndCropAll() {
        guard !busy, !state.pages.isEmpty else { return }
        drawingStraightenLine = false
        busy = true
        let snapshots = state.pages.filter { !$0.reviewed }
        guard !snapshots.isEmpty else {
            busy = false
            status = "All pages are already marked done"
            return
        }
        let pages = snapshots.map { page -> ScanPage in
            var snapshot = page; snapshot.edits = resolvedEdits(for: page); return snapshot
        }
        batchRunning = true
        batchTask = Task {
            var affected: [ScanPage] = []
            var failures: [String] = []
            var missingEdges = 0
            for (n, page) in pages.enumerated() {
                if Task.isCancelled { break }
                status = "Straightening and cropping \(n+1) of \(pages.count)…"
                let url = root.appendingPathComponent("Originals").appendingPathComponent(page.storedFile)
                let result = await Task.detached(priority: .utility) { () -> AutoResult? in
                    autoreleasepool {
                        guard let source = Imaging.load(url, maxSize: 1800) else { return nil }
                        var edits = page.edits; edits.angle = 0
                        guard let rotated = Imaging.render(source, edits: edits, crop: false) else { return nil }
                        edits.angle = Imaging.textAngle(rotated)
                        return Imaging.autoCrop(source, edits: edits)
                    }
                }.value
                if Task.isCancelled { break }
                guard let result else { failures.append(page.name); continue }
                if !result.found { missingEdges += 1 }
                guard let i = state.pages.firstIndex(where: { $0.id == page.id }) else { continue }
                affected.append(snapshots[n])
                state.pages[i].edits = result.edits
                state.pages[i].hasBeenEdited = true
                state.pages[i].reviewed = false
            }
            if !affected.isEmpty { remember(.batch(affected)) }
            save(); refresh()
            batchRunning = false
            batchTask = nil
            busy = false
            status = Task.isCancelled
                ? "Stopped · straightened and cropped \(affected.count) pages · Undo restores these pages"
                : "Straightened and cropped \(affected.count) pages · review before marking done"
            if missingEdges > 0 { status += " · \(missingEdges) need a manual crop check" }
            if !failures.isEmpty { error = "Could not process:\n" + failures.joined(separator: "\n") }
        }
    }
    func applyCopied(_ parity: Bool) {
        guard let copied, let i = index else { return }
        let targets = state.pages.indices.filter { $0 != i && (!parity || $0 % 2 == i % 2) }
        guard !targets.isEmpty else { return }
        remember(.batch(targets.map { state.pages[$0] }))
        for n in targets {
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
