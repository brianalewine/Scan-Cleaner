import SwiftUI
import AppKit

@main struct ScanCleanerApp: App {
    @StateObject private var projects = Projects()
    private var library: Library { projects.active }
    var body: some Scene {
        Window("Scan Cleaner", id: "main") {
            ProjectWorkspace().environmentObject(projects).frame(minWidth: 1000, minHeight: 680)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    _ = projects.save()
                }
                .alert("Scan Projects", isPresented: Binding(get: { projects.error != nil }, set: { if !$0 { projects.error = nil } })) {
                    Button("OK") { projects.error = nil }
                } message: { Text(projects.error ?? "") }
        }
        .defaultSize(width: 1320, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                ProjectControls().environmentObject(projects)
                Button("Import Scans…") { projects.importScans() }.keyboardShortcut("o").disabled(library.busy || library.showingPDFExport) }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Edit") { library.undo() }.keyboardShortcut("z").disabled(library.busy || library.showingPDFExport)
                Button("Undo Edit (Control-Z)") { library.undo() }.keyboardShortcut("z", modifiers: .control).disabled(library.busy || library.showingPDFExport)
            }
            CommandGroup(after: .undoRedo) {
                Button("Mark Done & Next") { library.markNext() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(library.page == nil || library.busy || library.showingPDFExport)
                Button("Stop Straightening") { library.cancelCurrentOperation() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!library.batchRunning && !library.drawingStraightenLine)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Progress") { _ = projects.save() }.keyboardShortcut("s")
            }
            CommandGroup(after: .saveItem) { Button("Export Cleaned Images…") { library.export() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(library.busy || library.state.pages.isEmpty || library.showingPDFExport) }
        }

    }
}
struct ContentView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var projects: Projects
    @State private var showingDeleteConfirmation = false
    @AppStorage("showingInspector") private var showingInspector = true
    @AppStorage("showingSidebar") private var showingSidebar = true
    @StateObject private var backdrop = ScanBackdropState()
    var body: some View {
        ZStack {
            GeometryReader { contentArea in
            HSplitView {
                if showingSidebar {
                    sidebar.frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                }
                VStack(spacing: 0) {
                    ScanCanvas(backdrop: backdrop).disabled(library.hasMultipleSelection).frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack {
                        Button { library.next(-1) } label: { Label("Previous", systemImage: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: [.command])
                            .disabled(library.index == nil || library.index == 0)
                        Spacer()
                        if let i = library.index { Text("\(i+1) / \(library.state.pages.count)").monospacedDigit().foregroundStyle(.secondary) }
                        Spacer()
                        Button(library.readyForPDF ? "Prepare for PDF Export" : "Mark Done & Next", systemImage: library.readyForPDF ? "doc.richtext" : "checkmark.circle") {
                            if library.readyForPDF {
                                library.cancelStraightenLine()
                                library.showingPDFExport = true
                            } else {
                                library.markNext()
                            }
                        }
                            .help(library.readyForPDF ? "Prepare all reviewed pages for PDF export (Return)" : "Mark this page as done, save it, and select the next page (Return)")
                            .keyboardShortcut(.return, modifiers: []).scanProminentButton()
                            .tint(library.readyForPDF ? Color.green : Color.accentColor)
                        Button { library.next(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next page").help("Next page (⌘→)").keyboardShortcut(.rightArrow, modifiers: [.command]).disabled(library.index == nil || library.index == library.state.pages.count-1)
                    }.scanGlassButtons().padding(14).disabled(library.page == nil || library.busy)
                }
                .frame(minWidth: 420)
                if showingInspector {
                    inspector.frame(minWidth: 285, idealWidth: 310, maxWidth: 380)
                }
            }
            // An explicit viewport prevents descendant scroll views from
            // expanding into the unified toolbar safe area. The small outer
            // inset also keeps their scroll edges off the titlebar boundary.
            .padding(.top, 1)
            .frame(width: contentArea.size.width, height: contentArea.size.height)
            .clipped()
            }
            .navigationTitle(projects.activeName)
            // Keep the native list, thumbnails, and canvas state alive during export.
            .opacity(library.showingPDFExport ? 0 : 1)
            .disabled(library.showingPDFExport)
            .allowsHitTesting(!library.showingPDFExport)
            .accessibilityHidden(library.showingPDFExport)
            if library.showingPDFExport {
                PDFExportView()
            }
        }
        // Keep scrolling controls inside the content area below the titlebar.
        .clipped()
        .background {
            SharedScanBackdrop(state: backdrop, image: library.showingPDFExport ? nil : library.preview)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) { ProjectControls() }
            ToolbarItem(placement: .navigation) {
                Button("Pages", systemImage: "sidebar.left") { showingSidebar.toggle() }
                    .help("Show or hide pages").disabled(library.showingPDFExport)
            }
            if !library.showingPDFExport {
                ToolbarItem(placement: .principal) {
                    // Center progress on the window, independently of the action group.
                    // Keep its width stable when progress appears or disappears.
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                            .opacity(library.busy ? 1 : 0)
                        Text(library.busy || library.drawingStraightenLine ? library.status : "")
                            .font(.caption).monospacedDigit().lineLimit(1)
                        Button { library.stopStraightenAndCrop() } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Stop straightening and cropping (Esc)")
                        .accessibilityLabel("Stop straightening and cropping")
                        .disabled(!library.batchRunning)
                        .opacity(library.batchRunning ? 1 : 0)
                    }
                    .frame(width: 280)
                    .opacity(library.busy || library.drawingStraightenLine ? 1 : 0)
                    .help(library.status)
                }
            }
            if #available(macOS 26.0, *) {
                // A real NSToolbar flexible space keeps the actions at the trailing edge.
                ToolbarSpacer(.flexible, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) { Spacer().frame(minWidth: 16) }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Group {
                Toggle(isOn: $library.grid) { Label("Grid", systemImage: "grid") }
                    .help("Show alignment grid")
                Toggle(isOn: $library.showOriginal) { Label("Original", systemImage: "doc") }
                    .help("Show original scan")
                Toggle(isOn: $library.croppedPreview) { Label("Crop preview", systemImage: "crop") }
                    .help("Preview cropped page")
            }
            .toggleStyle(.button)
            .disabled(library.page == nil || library.busy || library.showingPDFExport)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Adjustments", systemImage: "sidebar.right") { showingInspector.toggle() }
                    .help("Show or hide adjustments")
                    .disabled(library.showingPDFExport)
            }
            ToolbarItem(placement: .primaryAction) { Button("Export Images", systemImage: "square.and.arrow.up") { library.export() }.disabled(library.busy || library.state.pages.isEmpty || library.showingPDFExport) }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    library.cancelStraightenLine()
                    library.showingPDFExport = true
                } label: {
                    Label {
                        Text("PDF Export…")
                    } icon: {
                        Image(systemName: "doc.richtext")
                            .foregroundStyle(library.readyForPDF ? Color.green : Color.primary)
                    }
                }
                .disabled(library.busy || !library.readyForPDF || library.showingPDFExport)
                .help(library.readyForPDF ? "All pages are done — prepare a PDF" : "Mark every page done to prepare a PDF")
            }
        }
        .alert("Scan Cleaner", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("OK") { library.error = nil } } message: { Text(library.error ?? "") }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Pages", systemImage: "doc.on.doc").font(.headline)
                Spacer()
                Text("\(library.state.pages.filter(\.reviewed).count) done").font(.caption).foregroundStyle(.secondary)
                Button { projects.importScans() } label: { Image(systemName: "doc.badge.plus") }
                    .buttonStyle(.borderless).help("Import pages into this project")
                    .accessibilityLabel("Import pages").disabled(library.busy || library.showingPDFExport)
            }.padding(.horizontal, 15).padding(.top, 16)
            Button {
                if let page = library.state.pages.first(where: { !$0.reviewed }) {
                    library.select(page.id)
                }
            } label: {
                Label("Jump to unmarked", systemImage: "arrow.down.to.line")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Select the first page that has not been marked done")
            .disabled(library.busy || !library.state.pages.contains(where: { !$0.reviewed }))
            .padding(.horizontal, 15)
            PageList().environmentObject(library).disabled(library.busy)
            Button("Delete Page…", systemImage: "trash", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .disabled(library.page == nil || library.hasMultipleSelection || library.busy)
            .padding(.horizontal, 15)
            .alert("Delete this page?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete Page", role: .destructive) { library.deletePage() }
            } message: {
                Text("Remove \(library.page?.name ?? "this page") from the library? Your original file stays untouched. You can import it again later.")
            }
            Text("Shift-click for a range; Control-click or ⌘-click for individual pages. Drag selected pages to rearrange them.").font(.caption).foregroundStyle(.secondary).padding(15)
        }
        .scanGlassButtons()
    }
    func binding(_ key: WritableKeyPath<PageEdits, Double>) -> Binding<Double> {
        Binding(get: { library.edits[keyPath: key] }, set: { value in guard value.isFinite else { return }; var e = library.edits; e[keyPath: key] = key == \.angle ? min(12, max(-12, value)) : value; library.edit(e) })
    }
    func spineBinding<Value>(_ key: WritableKeyPath<SpineSettings, Value>) -> Binding<Value> {
        Binding(get: { library.edits.spineSettings[keyPath: key] }, set: { value in
            var settings = library.edits.spineSettings
            settings[keyPath: key] = value
            library.editSpine(settings)
        })
    }
    func cropSlider(_ title: String, _ key: WritableKeyPath<PageEdits, Double>, opposite: Double) -> some View {
        VStack(spacing: 4) {
            HStack { Text(title); Spacer(); Text(String(format: "%.1f%%", library.edits[keyPath: key]*100)).monospacedDigit().foregroundStyle(.secondary) }
            ResettableSlider(value: binding(key), range: 0...min(0.45, 0.95-opposite), step: 0.001, label: "\(title) crop")
                .frame(height: 20)
        }.font(.caption)
    }
    var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Adjustments", systemImage: "slider.horizontal.3").font(.headline)
                        Spacer()
                        Button("Reset") { library.resetPage() }.help("Reset all adjustments for this page (⌘Z to undo)")
                    }
                    Button { library.straightenAndCropAll() } label: {
                        HStack {
                            Image(systemName: "wand.and.stars").frame(width: 18)
                            Text("Straighten & Crop All Pages")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.scanProminentButton().controlSize(.large)
                    .help("Automatically straighten and crop pages without a green check. Undo reverts the entire run.")
                    Text("Review each page after processing. Press ⌘Z or Control-Z to undo the entire run.").font(.caption).foregroundStyle(.secondary)
                }.settingsSection()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Straighten", systemImage: "rotate.right").font(.headline)
                        Spacer()
                        Button { var e = library.edits; e.quarterTurns = (e.quarterTurns+1)%4; library.edit(e) } label: { Image(systemName: "rotate.left") }.help("Rotate 90°")
                        Button { library.resetRotation() } label: { Image(systemName: "arrow.counterclockwise") }
                            .foregroundStyle(.secondary).help("Reset this page's rotation").accessibilityLabel("Reset rotation")
                    }
                    HStack {
                        HStack(spacing: 2) {
                            TextField("Angle", value: binding(\.angle), format: .number.precision(.fractionLength(2)))
                                .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                                .accessibilityLabel("Straighten angle in degrees")
                            Text("°").accessibilityHidden(true)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.3)))
                    }
                    ResettableSlider(value: binding(\.angle), range: -12...12, step: 0.05, label: "Straighten angle")
                        .frame(height: 20)
                    Button("Auto Straighten Page", systemImage: "text.alignleft") { library.straightenPage() }
                        .help("Automatically level the text on this page (⌘Z to undo)")
                    Button(library.drawingStraightenLine ? "Cancel Line (Esc)" : "Draw Line to Straighten", systemImage: "line.diagonal") {
                        if library.drawingStraightenLine { library.cancelStraightenLine() }
                        else { library.beginStraightenLine() }
                    }
                    Text("Click two points along a line of text to level it. Press Esc to cancel.").font(.caption).foregroundStyle(.secondary)
                    Text("Align a line of text with the grid.").font(.caption).foregroundStyle(.secondary)
                }.settingsSection()
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label("Crop edges", systemImage: "crop").font(.headline)
                        Spacer()
                        Button { library.resetCrop() } label: { Image(systemName: "arrow.counterclockwise") }
                            .foregroundStyle(.secondary).help("Reset this page's crop").accessibilityLabel("Reset crop")
                    }
                    Button("Auto Detect Page Edges", systemImage: "viewfinder") { library.autoCrop() }
                    Text("Auto crop keeps the current rotation and looks for the page edge inside any visible stack of sheets.").font(.caption).foregroundStyle(.secondary)
                    Text("Drag an edge or corner to resize the crop. Use these sliders to fine-tune.").font(.caption).foregroundStyle(.secondary)
                    cropSlider("Left", \.left, opposite: library.edits.right)
                    cropSlider("Right", \.right, opposite: library.edits.left)
                    cropSlider("Top", \.top, opposite: library.edits.bottom)
                    cropSlider("Bottom", \.bottom, opposite: library.edits.top)
                }.settingsSection()
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Spine shadow", isOn: spineBinding(\.enabled)).font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Side", selection: spineBinding(\.side)) {
                            Text("Left").tag(SpineSide.left)
                            Text("Right").tag(SpineSide.right)
                        }.pickerStyle(.segmented)
                        HStack { Text("Width"); Spacer(); Text("\(library.edits.spineSettings.width*100, specifier: "%.1f")% of page").monospacedDigit() }.font(.caption)
                        ResettableSlider(value: spineBinding(\.width), range: 0.01...0.75, step: 0.001, label: "Spine width", resetValue: SpineSettings().width)
                            .frame(height: 20)
                        HStack { Text("Strength"); Spacer(); Text("\(library.edits.spineSettings.strength*100, specifier: "%.1f")%").monospacedDigit() }.font(.caption)
                        ResettableSlider(value: spineBinding(\.strength), range: 0...1, step: 0.001, label: "Spine strength", resetValue: SpineSettings().strength)
                            .frame(height: 20)
                    }.disabled(!library.edits.spineSettings.enabled)
                    if library.edits.spine == nil && library.edits.shadow > 0 {
                        Text("This page keeps its previous two-sided correction until you change a shadow control.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Changes become the default for untouched pages. Adjusted pages keep their settings. Width is measured from the selected side of the full scan.").font(.caption).foregroundStyle(.secondary)

                }.settingsSection()
                VStack(alignment: .leading, spacing: 9) {
                    Label("Reuse settings", systemImage: "doc.on.clipboard").font(.headline)
                    HStack {
                        Button("Copy") { library.copied = library.edits }
                        Button("Paste") { if let copied = library.copied { library.edit(copied) } }.disabled(library.copied == nil)
                    }
                    Menu("Apply copied settings…") {
                        Button("To same odd/even pages") { library.applyCopied(true) }
                        Button("To all pages") { library.applyCopied(false) }
                    }.disabled(library.copied == nil)
                    Text("Odd/even follows the page list order. Batch changes clear done marks.").font(.caption).foregroundStyle(.secondary)
                }.settingsSection()
                Text("Double-click a slider to reset it.\n⌘Z undo • ↵ done & next\n⌘← / ⌘→ previous / next").font(.caption).foregroundStyle(.secondary)
            }.padding(14)
        }
        // Preserve the automatic toolbar safe-area inset for the first card.
        .frame(maxHeight: .infinity, alignment: .top)
        .scanGlassButtons().disabled(library.page == nil || library.hasMultipleSelection || library.busy || library.showOriginal)
    }
}
struct PageThumbnail: View {
    @EnvironmentObject var library: Library
    let page: ScanPage
    @State private var thumbnail: CGImage?
    var body: some View {
        let edits = library.resolvedEdits(for: page)
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .controlBackgroundColor))
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFit().padding(2)
            } else {
                Image(systemName: "doc.richtext").foregroundStyle(.secondary)
            }
        }
        .frame(width: 38, height: 50)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.25)))
        .accessibilityHidden(true)
        .task(id: edits) {
            // Avoid decoding and rendering sidebar thumbnails on every drag event.
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return }
            let result = await library.thumbnail(for: page, edits: edits)
            guard !Task.isCancelled else { return }
            thumbnail = result
        }
    }
}
struct ScanCanvas: View {
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject var projects: Projects
    @EnvironmentObject var library: Library
    let backdrop: ScanBackdropState
    @State private var drag: CGRect?
    @State private var cropDrag: CropDrag?
    @State private var zoom: CGFloat = 1
    var body: some View {
      VStack(spacing: 0) {
        GeometryReader { geo in
            ZStack {
                Color.clear
                if let image = library.preview {
                    let factor = max(0.01, min((geo.size.width-48)/CGFloat(image.width), (geo.size.height-40)/CGFloat(image.height))) * zoom
                    let size = CGSize(width: CGFloat(image.width)*factor, height: CGFloat(image.height)*factor)
                    CursorZoomScrollView(zoom: $zoom, imageSize: size, backdrop: backdrop) {
                    ZStack {
                        Image(decorative: image, scale: 1).resizable().interpolation(.high).frame(width: size.width, height: size.height)
                        if !library.showOriginal && !library.croppedPreview && !library.drawingStraightenLine {
                            Canvas { context, canvas in
                                // Difference blending must share a drawing surface with the scan.
                                // Separate SwiftUI layers can blend against transparency instead.
                                context.draw(Image(decorative: image, scale: 1), in: CGRect(origin: .zero, size: canvas))
                                let e = library.edits
                                let r = drag ?? CGRect(x: e.left*canvas.width, y: e.top*canvas.height, width: (1-e.left-e.right)*canvas.width, height: (1-e.top-e.bottom)*canvas.height)
                                var mask = Path(CGRect(origin: .zero, size: canvas)); mask.addRect(r)
                                context.fill(mask, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                                context.blendMode = .difference
                                let hairline = 1 / max(displayScale, 1)
                                if library.grid {
                                    var grid = Path()
                                    for i in 1..<16 { let y = r.minY + r.height*Double(i)/16; grid.move(to: CGPoint(x: r.minX, y: y)); grid.addLine(to: CGPoint(x: r.maxX, y: y)) }
                                    for i in 1..<4 { let x = r.minX+r.width*Double(i)/4; grid.move(to: CGPoint(x: x, y: r.minY)); grid.addLine(to: CGPoint(x: x, y: r.maxY)) }
                                    context.stroke(grid, with: .color(.white), lineWidth: hairline)
                                }
                                context.stroke(Path(r), with: .color(.white), lineWidth: hairline)
                                for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)] {
                                    // Keep the full handle visible when the crop reaches a page edge.
                                    let center = CGPoint(x: min(max(p.x, 3), canvas.width - 3), y: min(max(p.y, 3), canvas.height - 3))
                                    let handle = Path(roundedRect: CGRect(x: center.x-3, y: center.y-3, width: 6, height: 6), cornerRadius: 1)
                                    context.stroke(handle, with: .color(.white), lineWidth: hairline)
                                }
                            }.frame(width: size.width, height: size.height)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                if cropDrag == nil {
                                    let e = library.edits
                                    let interaction = CropDrag(start: value.startLocation, crop: CGRect(x: e.left, y: e.top, width: 1-e.left-e.right, height: 1-e.top-e.bottom), size: size)
                                    guard interaction.isResizing else { return }
                                    cropDrag = interaction
                                }
                                if let rect = cropDrag?.updated(translation: value.translation) {
                                    drag = CGRect(x: rect.minX*size.width, y: rect.minY*size.height, width: rect.width*size.width, height: rect.height*size.height)
                                }
                            }.onEnded { value in
                                if let r = cropDrag?.updated(translation: value.translation) {
                                    var e = library.edits
                                    e.setCrop(CGRect(x: r.minX, y: 1-r.maxY, width: r.width, height: r.height))
                                    library.edit(e)
                                }
                                drag = nil
                                cropDrag = nil
                            })
                            .transaction { $0.animation = nil }
                            .disabled(library.busy)
                        }
                        if library.drawingStraightenLine && !library.showOriginal && !library.croppedPreview {
                            StraightenLineOverlay(size: size).frame(width: size.width, height: size.height)
                        }
                    }.environmentObject(library).shadow(radius: 8)
                        .padding(.horizontal, 24).padding(.vertical, 20)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                } else if library.page == nil {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.viewfinder").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(Color.accentColor)
                        Text("A clean page, every time.").font(.title2.bold())
                        Text("Import your scans, trim the edges, and straighten the text.\nPick up exactly where you left off.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Import Scans…") { projects.importScans() }.scanProminentButton().controlSize(.large)
                    }
                } else { ProgressView() }
            }
            .clipped()
        }
        .overlay(alignment: .bottom) {
        HStack(spacing: 10) {
            Text("Zoom").font(.caption).foregroundStyle(.secondary)
            Button { zoom = max(1, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .accessibilityLabel("Zoom out").help("Zoom out").disabled(zoom <= 1)
            Text(String(format: "%.0f%%", zoom * 100)).font(.caption.monospacedDigit()).frame(width: 44)
                .help("Magnification relative to Fit")
            Button { zoom = min(6, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .accessibilityLabel("Zoom in").help("Zoom in").disabled(zoom >= 6)
            Button("Fit") { zoom = 1 }.help("Fit the whole page in the viewer")

        }
        .buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 10)
        .scanGlassSurface()
        .help("Pinch to zoom · Scroll to pan")
        .disabled(library.preview == nil)
        .padding(16)
        }

      }
        .onAppear { zoom = library.state.zoom ?? 1 }
        .onChange(of: zoom) { _, value in
            drag = nil; cropDrag = nil
            library.state.zoom = value
            library.save()
        }
        .onChange(of: library.state.selection) { _, _ in zoom = 1 }
        .onChange(of: library.state.selection) { _, _ in drag = nil; cropDrag = nil }
        .onChange(of: library.showOriginal) { _, _ in drag = nil; cropDrag = nil }
        .onChange(of: library.croppedPreview) { _, _ in drag = nil; cropDrag = nil }
        .onChange(of: library.drawingStraightenLine) { _, _ in drag = nil; cropDrag = nil }
        .onChange(of: library.showOriginal) { _, value in if value { library.cancelStraightenLine() } }
        .onChange(of: library.croppedPreview) { _, value in if value { library.cancelStraightenLine() } }
        .onChange(of: library.busy) { _, value in if value { library.cancelStraightenLine() } }
    }
}

struct StraightenLineOverlay: View {
    @EnvironmentObject var library: Library
    let size: CGSize
    @State private var first: CGPoint?
    @State private var hover: CGPoint?
    var body: some View {
        Canvas { context, canvas in
            if let first {
                let a = CGPoint(x: first.x * canvas.width, y: first.y * canvas.height)
                if let hover {
                    let b = CGPoint(x: hover.x * canvas.width, y: hover.y * canvas.height)
                    var line = Path(); line.move(to: a); line.addLine(to: b)
                    context.stroke(line, with: .color(.black), lineWidth: 1.5)
                    context.stroke(line, with: .color(.white), lineWidth: 0.5)
                    let dot = Path(ellipseIn: CGRect(x: b.x-2.5, y: b.y-2.5, width: 5, height: 5))
                    context.fill(dot, with: .color(.white))
                    context.stroke(dot, with: .color(.black), lineWidth: 0.75)
                }
                let dot = Path(ellipseIn: CGRect(x: a.x-2.5, y: a.y-2.5, width: 5, height: 5))
                context.fill(dot, with: .color(.white))
                context.stroke(dot, with: .color(.black), lineWidth: 0.75)
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
            let point = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
            if let first {
                let a = CGPoint(x: first.x * size.width, y: first.y * size.height)
                if !library.straightenLine(from: a, to: value.location) { self.first = nil }
            } else {
                first = point
                library.status = "Click the second point · Esc to cancel"
            }
        })
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hover = CGPoint(x: point.x / size.width, y: point.y / size.height)
                NSCursor.crosshair.set()
            case .ended: hover = nil; NSCursor.arrow.set()
            }
        }
        .onDisappear { NSCursor.arrow.set() }
    }
}
