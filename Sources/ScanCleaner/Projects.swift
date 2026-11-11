import SwiftUI
import AppKit

struct ScanProject: Codable, Identifiable {
    var id: UUID
    var name: String
    var pageCount: Int = 0
    var updated: Date = Date()
}

struct ProjectSession: Codable {
    var activeID: UUID?
    var showingLibrary: Bool
    var showingPDFExport: Bool = false
}

struct ProjectStorage {
    var total: Int64 = 0
    var edits: Int64 = 0
    static func measure(_ folder: URL) -> ProjectStorage {
        var result = ProjectStorage()
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return result }
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            result.total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            if url.pathExtension == "json" { result.edits += Int64(values.fileSize ?? 0) }
        }
        return result
    }
    static func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

@MainActor final class Projects: ObservableObject {
    @Published private(set) var items: [ScanProject] = []
    @Published private(set) var active: Library
    @Published private(set) var activeID: UUID? { didSet { saveSession() } }
    @Published var showingLibrary = true { didSet { saveSession() } }
    private var restoring = true
    @Published var error: String?
    let root: URL
    var locked: Bool { active.busy || active.showingPDFExport }
    var activeName: String { items.first { $0.id == activeID }?.name ?? "New Scan" }

    init(root: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var migrationError: Error?
        if root == nil {
            do { try Library.migrateLibrary(in: support) } catch { migrationError = error }
        }
        self.root = root ?? support.appendingPathComponent("Scan Cleaner")
        // An unsaved empty workspace does not become a project until requested.
        active = Library(root: self.root.appendingPathComponent("Workspace"))
        do {
            if let migrationError { throw migrationError }
            let folder = self.root.appendingPathComponent("Projects")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
                let metadata = url.appendingPathComponent("project.json")
                let project = try JSONDecoder().decode(ScanProject.self, from: Data(contentsOf: metadata))
                guard project.id == id else { continue }
                items.append(project)
            }
            let legacy = self.root.appendingPathComponent("library.json")
            let marker = self.root.appendingPathComponent("projects-migrated")
            if FileManager.default.fileExists(atPath: legacy.path), !FileManager.default.fileExists(atPath: marker.path) {
                let state = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: legacy))
                if !state.pages.isEmpty {
                    let project = ScanProject(id: UUID(), name: "Existing Scans", pageCount: state.pages.count)
                    let destination = projectURL(project.id)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: legacy, to: destination.appendingPathComponent("library.json"))
                    let originals = self.root.appendingPathComponent("Originals")
                    if FileManager.default.fileExists(atPath: originals.path) {
                        try FileManager.default.copyItem(at: originals, to: destination.appendingPathComponent("Originals"))
                    }
                    try write(project)
                    items.append(project)
                }
                try Data().write(to: marker, options: .atomic)
            }
            // Refresh counts from the authoritative saved page state.
            for index in items.indices {
                let url = projectURL(items[index].id).appendingPathComponent("library.json")
                if let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(LibraryState.self, from: data) {
                    items[index].pageCount = state.pages.count
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let date = attributes[.modificationDate] as? Date { items[index].updated = date }
                }
            }
            items.sort { $0.updated > $1.updated }
            let session = try? JSONDecoder().decode(ProjectSession.self, from: Data(contentsOf: self.root.appendingPathComponent("session.json")))
            if let id = session?.activeID, items.contains(where: { $0.id == id }) { open(id) }
            else if let first = items.first { open(first.id) }
            showingLibrary = session?.showingLibrary ?? true
            if activeID == nil { showingLibrary = true }
            active.showingPDFExport = !showingLibrary && (session?.showingPDFExport ?? false) && active.readyForPDF
        } catch { self.error = "Could not open scan projects: \(error.localizedDescription)" }
        restoring = false
    }

    func saveSession() {
        guard !restoring else { return }
        do {
            let session = ProjectSession(activeID: activeID, showingLibrary: showingLibrary, showingPDFExport: active.showingPDFExport)
            try JSONEncoder().encode(session).write(to: root.appendingPathComponent("session.json"), options: .atomic)
        } catch { self.error = "Could not save window state: \(error.localizedDescription)" }
    }
    func importScans() {
        if activeID == nil { create(name: "Untitled Scan") }
        guard activeID != nil else { return }
        active.importScans()
    }
    func projectURL(_ id: UUID) -> URL { root.appendingPathComponent("Projects").appendingPathComponent(id.uuidString) }
    private func write(_ project: ScanProject) throws {
        try JSONEncoder().encode(project).write(to: projectURL(project.id).appendingPathComponent("project.json"), options: .atomic)
    }
    @discardableResult func save() -> Bool {
        active.save()
        saveSession()
        guard active.error == nil else { error = active.error; return false }
        guard let index = items.firstIndex(where: { $0.id == activeID }) else { return true }
        var project = items[index]
        project.pageCount = active.state.pages.count
        project.updated = Date()
        do { try write(project); items[index] = project; return true }
        catch { self.error = "Could not save project: \(error.localizedDescription)"; return false }
    }
    func create(name: String) {
        guard !locked, save() else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = ScanProject(id: UUID(), name: trimmed.isEmpty ? "Untitled Scan" : trimmed)
        do {
            try FileManager.default.createDirectory(at: projectURL(project.id), withIntermediateDirectories: true)
            try write(project)
            let library = Library(root: projectURL(project.id))
            guard library.error == nil else { error = library.error; return }
            items.insert(project, at: 0)
            activeID = project.id
            active = library
            showingLibrary = false
        } catch { self.error = "Could not create project: \(error.localizedDescription)" }
    }
    func open(_ id: UUID) {
        guard !locked, items.contains(where: { $0.id == id }), save() else { return }
        if id == activeID { showingLibrary = false; return }
        let library = Library(root: projectURL(id))
        guard library.error == nil else { error = library.error; return }
        activeID = id
        active = library
        showingLibrary = false
    }
    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return }
        var project = items[index]
        project.name = trimmed
        do { try write(project); items[index] = project }
        catch { self.error = "Could not rename project: \(error.localizedDescription)" }
    }
    func savedState(for id: UUID) -> LibraryState? {
        if id == activeID { return active.state }
        guard let data = try? Data(contentsOf: projectURL(id).appendingPathComponent("library.json")) else { return nil }
        return try? JSONDecoder().decode(LibraryState.self, from: data)
    }
    func showLibrary() {
        guard !locked, save() else { return }
        showingLibrary = true
    }
    func delete(_ id: UUID) {
        guard !locked, items.contains(where: { $0.id == id }) else { return }
        do {
            // Trash preserves a recovery path for the entire project and its originals.
            try FileManager.default.trashItem(at: projectURL(id), resultingItemURL: nil)
            items.removeAll { $0.id == id }
            if activeID == id {
                active.cancelPendingSave()
                showingLibrary = true
                activeID = nil
                active = Library(root: root.appendingPathComponent("Workspace"))
            }
        } catch { self.error = "Could not delete project: \(error.localizedDescription)" }
    }
}

struct ProjectControls: View {
    @EnvironmentObject var projects: Projects
    @State private var creating = false
    @State private var name = ""
    var body: some View {
        HStack {
            Button("Scan Library", systemImage: "square.grid.2x2") { projects.showLibrary() }
                .disabled(projects.locked)
            Button("New Scan Project", systemImage: "plus") { name = ""; creating = true }
                .labelStyle(.iconOnly).help("Start a new scan project")
                .disabled(projects.locked)

        }
        .alert("New Scan Project", isPresented: $creating) {
            TextField("Project name", text: $name)
            Button("Create") { projects.create(name: name) }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Your current project is saved before starting a new one.") }
    }
}

struct ProjectWorkspace: View {
    @EnvironmentObject var projects: Projects
    var body: some View {
        Group {
            if projects.showingLibrary {
                ScanLibraryView(library: projects.active)
            } else {
                ContentView().id(projects.activeID).environmentObject(projects.active)
            }
        }
    }
}

struct ScanLibraryView: View {
    @EnvironmentObject var projects: Projects
    @ObservedObject var library: Library
    @State private var deleting: ScanProject?
    @State private var renaming: ScanProject?
    @State private var name = ""
    @State private var storage = ProjectStorage()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan Library").font(.largeTitle.bold())
            Text("Your projects and progress are saved automatically.").foregroundStyle(.secondary)
            Text("App storage: \(ProjectStorage.format(storage.total)) · Includes copied scans and saved edits")
                .font(.caption).foregroundStyle(.secondary)
            if projects.items.isEmpty {
                ContentUnavailableView("No Scan Projects", systemImage: "doc.on.doc", description: Text("Click + to start a new scan project."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 310))], alignment: .leading, spacing: 20) {
                        ForEach(projects.items) { project in
                            ScanProjectCard(project: project, state: projects.savedState(for: project.id),
                                folder: projects.projectURL(project.id), locked: projects.locked,
                                open: { projects.open(project.id) },
                                rename: { name = project.name; renaming = project },
                                delete: { deleting = project })
                        }
                    }.padding(4)
                }
            }
            Spacer(minLength: 0)
        }.padding(28)
        .task(id: projects.items.map { "\($0.id)-\($0.updated)" }.joined()) {
            let root = projects.root
            let value = await Task.detached(priority: .utility) { ProjectStorage.measure(root) }.value
            if !Task.isCancelled { storage = value }
        }
        .navigationTitle("Scan Library")
        .toolbar { ToolbarItem(placement: .primaryAction) { ProjectControls() } }
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Project name", text: $name)
            Button("Save") { if let renaming { projects.rename(renaming.id, to: name) }; renaming = nil }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Delete Scan Project?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) { if let deleting { projects.delete(deleting.id) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("“\(deleting?.name ?? "")” and all its pages and saved edits will be moved to the Trash.") }
    }
}

struct ScanProjectCard: View {
    let project: ScanProject
    let state: LibraryState?
    let folder: URL
    let locked: Bool
    let open: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @State private var hovered = false
    @State private var thumbnail: CGImage?
    @State private var storage = ProjectStorage()
    private var complete: Bool {
        guard let pages = state?.pages else { return false }
        return !pages.isEmpty && pages.allSatisfy(\.reviewed)
    }
    @ViewBuilder private var actions: some View {
        Button("Rename…", systemImage: "pencil", action: rename).disabled(locked)
        Button("Delete…", systemImage: "trash", role: .destructive, action: delete).disabled(locked)
    }
    private var thumbnailKey: String {
        guard let page = state?.pages.first else { return "empty" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let edits = (try? encoder.encode(page.edits).base64EncodedString()) ?? ""
        let defaults = (try? encoder.encode(state?.spineDefaults).base64EncodedString()) ?? ""
        return folder.path + page.storedFile + edits + defaults + String(page.isAdjusted)
    }
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                Color(nsColor: .controlBackgroundColor)
                    .frame(height: 220)
                    .overlay {
                        GeometryReader { geometry in
                            if let thumbnail {
                                Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            } else {
                                Image(systemName: "doc.richtext").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(project.name).font(.headline).lineLimit(2)
                    Spacer(minLength: 0)
                    if complete {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .accessibilityLabel("All pages complete").help("All pages complete")
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(state?.pages.count ?? project.pageCount) pages · \(ProjectStorage.format(storage.total)) on disk")
                        Text("Edits: \(ProjectStorage.format(storage.edits))")
                    }.font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Color.clear.frame(width: 24, height: 24)
                }
            }
            .padding(12)
            .background(hovered ? Color(nsColor: .controlColor) : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hovered ? Color.gray.opacity(0.4) : Color.secondary.opacity(0.18)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).disabled(locked)
        .overlay(alignment: .bottomTrailing) {
            Menu { actions } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Options for \(project.name)")
            .opacity(hovered ? 1 : 0)
            .disabled(locked)
            .padding(12)
        }
        .onHover { hovered = $0 }
        .contextMenu { actions }
        .task(id: project.updated) {
            let value = await Task.detached(priority: .utility) { ProjectStorage.measure(folder) }.value
            if !Task.isCancelled { storage = value }
        }
        .task(id: thumbnailKey) {
            guard let page = state?.pages.first else { thumbnail = nil; return }
            var edits = page.edits
            if !page.isAdjusted {
                var defaults = state?.spineDefaults ?? SpineSettings()
                defaults.enabled = page.edits.spineSettings.enabled
                edits.spineSettings = defaults
            }
            let url = folder.appendingPathComponent("Originals").appendingPathComponent(page.storedFile)
            let snapshot = edits
            let result = await Task.detached(priority: .utility) {
                guard let image = Imaging.load(url, maxSize: 500) else { return nil as CGImage? }
                return Imaging.render(image, edits: snapshot, crop: true)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = result
        }
    }
}
