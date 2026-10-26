import SwiftUI
import AppKit

@main struct ScanTidyApp: App {
    @NSApplicationDelegateAdaptor(ScanTidyAppDelegate.self) private var appDelegate
    @StateObject private var library = Library()
    var body: some Scene {
        Window("Scan Tidy", id: "main") {
            ContentView().environmentObject(library).frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1320, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) { Button("Import Scans…") { library.importScans() }.keyboardShortcut("o").disabled(library.busy) }
            CommandGroup(replacing: .undoRedo) { Button("Undo Page Edit") { library.undo() }.keyboardShortcut("z").disabled(library.busy) }
            CommandGroup(after: .undoRedo) {
                Button("Cancel Line Straightening") { library.cancelStraightenLine() }
                    .keyboardShortcut(.escape, modifiers: []).disabled(!library.drawingStraightenLine)
            }
            CommandGroup(after: .saveItem) { Button("Export Cleaned Images…") { library.export() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(library.busy || library.state.pages.isEmpty) }
        }
    }
}
final class ScanTidyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}
struct ContentView: View {
    @EnvironmentObject var library: Library
    @State private var showingDeleteConfirmation = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 215)
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        Text(library.page?.name ?? "Your scan workspace").font(.headline).lineLimit(1)
                        Spacer()
                        Toggle("Grid", isOn: $library.grid).toggleStyle(.button)
                        Toggle("Original", isOn: $library.showOriginal).toggleStyle(.button)
                        Toggle("Crop preview", isOn: $library.croppedPreview).toggleStyle(.button)
                    }.padding(14)
                    ScanCanvas().frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack {
                        Button { library.next(-1) } label: { Label("Previous", systemImage: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: [.command])
                            .disabled(library.index == nil || library.index == 0)
                        Spacer()
                        if let i = library.index { Text("\(i+1) / \(library.state.pages.count)").monospacedDigit().foregroundStyle(.secondary) }
                        Spacer()
                        Button("Done & Next", systemImage: "checkmark.circle") { library.markNext() }.keyboardShortcut(.return, modifiers: [.command]).buttonStyle(.borderedProminent)
                        Button { library.next(1) } label: { Image(systemName: "chevron.right") }.disabled(library.index == nil || library.index == library.state.pages.count-1)
                    }.padding(14).disabled(library.page == nil || library.busy)
                }
                Divider()
                inspector.frame(width: 265)
            }
            Divider()
            HStack {
                if library.busy { ProgressView().controlSize(.small) }
                Text(library.status).lineLimit(1)
                Spacer()
                Label("Progress saved automatically", systemImage: "internaldrive").foregroundStyle(.secondary)
            }.font(.caption).padding(.horizontal, 16).padding(.vertical, 9)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Import Scans", systemImage: "plus") { library.importScans() }.disabled(library.busy) }
            ToolbarItem(placement: .primaryAction) { Button("Export Images", systemImage: "square.and.arrow.up") { library.export() }.disabled(library.busy || library.state.pages.isEmpty) }
        }
        .alert("Scan Tidy", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("OK") { library.error = nil } } message: { Text(library.error ?? "") }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("PAGES").font(.caption.bold()); Spacer(); Text("\(library.state.pages.filter(\.reviewed).count) done").font(.caption).foregroundStyle(.secondary) }.padding(.horizontal, 15).padding(.top, 16)
            ScrollViewReader { proxy in
              List(selection: Binding(get: { library.state.selection }, set: { library.select($0) })) {
                ForEach(Array(library.state.pages.enumerated()), id: \.element.id) { i, page in
                    HStack(spacing: 9) {
                        PageThumbnail(page: page)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text("Page \(i+1)").fontWeight(.medium)
                                if page.reviewed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done") }
                            }
                            Text(page.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }.padding(.vertical, 5).tag(page.id).id(page.id)
                }
                .onMove { offsets, destination in
                    library.movePages(from: offsets, to: destination)
                }
              }.listStyle(.sidebar).disabled(library.busy)
              .task {
                  // Wait for the native list to finish its initial layout.
                  await Task.yield()
                  if let selection = library.state.selection { proxy.scrollTo(selection, anchor: .center) }
              }
              .onChange(of: library.state.selection) { _, selection in
                  // Without an anchor, scrollTo only moves enough to reveal an
                  // offscreen row. A visible selection keeps the scroll position.
                  if let selection { proxy.scrollTo(selection) }
              }
            }
            Button("Delete Page…", systemImage: "trash", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .disabled(library.page == nil || library.busy)
            .padding(.horizontal, 15)
            .alert("Delete this page?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete Page", role: .destructive) { library.deletePage() }
            } message: {
                Text("Remove \(library.page?.name ?? "this page") from the library? Your original file stays untouched. You can import it again later.")
            }
            Text("Drag pages to rearrange them. Scans are copied into your library. Original files stay untouched.").font(.caption).foregroundStyle(.secondary).padding(15)
        }
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
                        Text("QUICK START").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { library.resetPage() }.help("Reset all adjustments for this page (⌘Z to undo)")
                    }
                    Button { library.autoAdjust() } label: {
                        HStack {
                            Image(systemName: "wand.and.stars").frame(width: 18)
                            Text("Suggest Crop & Angle")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button { library.straightenAll() } label: {
                        HStack {
                            Image(systemName: "text.alignleft").frame(width: 18)
                            Text("Straighten All Pages")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Check each suggestion. For pale page edges, adjust the blue crop lines yourself.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Straighten").font(.headline)
                        Spacer()
                        Button { var e = library.edits; e.quarterTurns = (e.quarterTurns+1)%4; library.edit(e) } label: { Image(systemName: "rotate.left") }.help("Rotate 90°")
                        Button { library.resetRotation() } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Reset this page's rotation").accessibilityLabel("Reset rotation")
                    }
                    HStack {
                        Button("−") { var e = library.edits; e.angle = max(-12, e.angle-0.05); library.edit(e) }
                        TextField("Angle", value: binding(\.angle), format: .number.precision(.fractionLength(2))).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        Text("°")
                        Button("+") { var e = library.edits; e.angle = min(12, e.angle+0.05); library.edit(e) }
                    }
                    ResettableSlider(value: binding(\.angle), range: -12...12, step: 0.05, label: "Straighten angle")
                        .frame(height: 20)
                    Button(library.drawingStraightenLine ? "Cancel Line (Esc)" : "Draw Line to Straighten", systemImage: "line.diagonal") {
                        if library.drawingStraightenLine { library.cancelStraightenLine() }
                        else { library.beginStraightenLine() }
                    }
                    Text("Click two points along a line of text to level it. Press Esc to cancel.").font(.caption).foregroundStyle(.secondary)
                    Text("Align a line of text with the grid.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Crop edges").font(.headline)
                        Spacer()
                        Button { library.resetCrop() } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Reset this page's crop").accessibilityLabel("Reset crop")
                    }
                    Button("Auto Detect Page Edges", systemImage: "viewfinder") { library.autoCrop() }
                    Text("Auto crop keeps the current rotation and looks for the page edge inside any visible stack of sheets.").font(.caption).foregroundStyle(.secondary)
                    Text("Drag a blue edge or corner to resize the crop. Use these sliders to fine-tune.").font(.caption).foregroundStyle(.secondary)
                    cropSlider("Left", \.left, opposite: library.edits.right)
                    cropSlider("Right", \.right, opposite: library.edits.left)
                    cropSlider("Top", \.top, opposite: library.edits.bottom)
                    cropSlider("Bottom", \.bottom, opposite: library.edits.top)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Spine shadow", isOn: spineBinding(\.enabled)).font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Side", selection: spineBinding(\.side)) {
                            Text("Left").tag(SpineSide.left)
                            Text("Right").tag(SpineSide.right)
                        }.pickerStyle(.segmented)
                        HStack { Text("Width"); Spacer(); Text("\(Int(library.edits.spineSettings.width*100))% of page").monospacedDigit() }.font(.caption)
                        ResettableSlider(value: spineBinding(\.width), range: 0.01...0.75, step: 0.01, label: "Spine width", resetValue: SpineSettings().width)
                            .frame(height: 20)
                        HStack { Text("Strength"); Spacer(); Text("\(Int(library.edits.spineSettings.strength*100))%").monospacedDigit() }.font(.caption)
                        ResettableSlider(value: spineBinding(\.strength), range: 0...1, step: 0.01, label: "Spine strength", resetValue: SpineSettings().strength)
                            .frame(height: 20)
                    }.disabled(!library.edits.spineSettings.enabled)
                    if library.edits.spine == nil && library.edits.shadow > 0 {
                        Text("This page keeps its previous two-sided correction until you change a shadow control.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Changes become the default for untouched pages. Adjusted pages keep their settings. Width is measured from the selected side of the full scan.").font(.caption).foregroundStyle(.secondary)

                }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text("Reuse settings").font(.headline)
                    HStack {
                        Button("Copy") { library.copied = library.edits }
                        Button("Paste") { if let copied = library.copied { library.edit(copied) } }.disabled(library.copied == nil)
                    }
                    Menu("Apply copied settings…") {
                        Button("To same odd/even pages") { library.applyCopied(true) }
                        Button("To all pages") { library.applyCopied(false) }
                    }.disabled(library.copied == nil)
                    Text("Odd/even follows the page list order. Batch changes clear done marks.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Double-click a slider to reset it.\n⌘Z undo • ⌘↵ done & next\n⌘← / ⌘→ previous / next").font(.caption).foregroundStyle(.secondary)
            }.padding(18)
        }.disabled(library.page == nil || library.busy || library.showOriginal)
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
            let result = await library.thumbnail(for: page, edits: edits)
            guard !Task.isCancelled else { return }
            thumbnail = result
        }
    }
}
struct ScanCanvas: View {
    @EnvironmentObject var library: Library
    @State private var drag: CGRect?
    @State private var cropDrag: CropDrag?
    @State private var zoom: CGFloat = 1
    @State private var pinchStart: CGFloat?
    var body: some View {
      VStack(spacing: 0) {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: NSColor(calibratedWhite: 0.14, alpha: 1))
                if let image = library.preview {
                    let factor = max(0.01, min((geo.size.width-48)/CGFloat(image.width), (geo.size.height-40)/CGFloat(image.height))) * zoom
                    let size = CGSize(width: CGFloat(image.width)*factor, height: CGFloat(image.height)*factor)
                    ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        Image(decorative: image, scale: 1).resizable().interpolation(.high).frame(width: size.width, height: size.height)
                        if !library.showOriginal && !library.croppedPreview && !library.drawingStraightenLine {
                            Canvas { context, canvas in
                                let e = library.edits
                                let r = drag ?? CGRect(x: e.left*canvas.width, y: e.top*canvas.height, width: (1-e.left-e.right)*canvas.width, height: (1-e.top-e.bottom)*canvas.height)
                                var mask = Path(CGRect(origin: .zero, size: canvas)); mask.addRect(r)
                                context.fill(mask, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                                if library.grid {
                                    var grid = Path()
                                    for i in 1..<16 { let y = r.minY + r.height*Double(i)/16; grid.move(to: CGPoint(x: r.minX, y: y)); grid.addLine(to: CGPoint(x: r.maxX, y: y)) }
                                    for i in 1..<4 { let x = r.minX+r.width*Double(i)/4; grid.move(to: CGPoint(x: x, y: r.minY)); grid.addLine(to: CGPoint(x: x, y: r.maxY)) }
                                    context.stroke(grid, with: .color(.cyan.opacity(0.4)), lineWidth: 0.6)
                                }
                                context.stroke(Path(r), with: .color(.cyan), lineWidth: 2)
                                for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] { context.fill(Path(ellipseIn: CGRect(x: p.x-4, y: p.y-4, width: 8, height: 8)), with: .color(.white)) }
                                for p in [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)] {
                                    context.fill(Path(roundedRect: CGRect(x: p.x-3, y: p.y-3, width: 6, height: 6), cornerRadius: 1), with: .color(.cyan))
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
                    }.shadow(radius: 8)
                        .padding(.horizontal, 24).padding(.vertical, 20)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                    .defaultScrollAnchor(.center)
                    .simultaneousGesture(MagnificationGesture().onChanged { value in
                        if pinchStart == nil { pinchStart = zoom }
                        zoom = min(6, max(1, (pinchStart ?? 1) * value))
                    }.onEnded { _ in pinchStart = nil })
                } else if library.page == nil {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.viewfinder").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(.cyan)
                        Text("A clean page, every time.").font(.title2.bold())
                        Text("Import your scans, trim the edges, and straighten the text.\nPick up exactly where you left off.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Import Scans…") { library.importScans() }.buttonStyle(.borderedProminent).controlSize(.large)
                    }.foregroundStyle(.white)
                } else { ProgressView().colorScheme(.dark) }
            }
            .clipped()
        }
        HStack(spacing: 10) {
            Text("Zoom").font(.caption).foregroundStyle(.secondary)
            Button { zoom = max(1, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out").disabled(zoom <= 1)
            Text(String(format: "%.0f%%", zoom * 100)).font(.caption.monospacedDigit()).frame(width: 44)
                .help("Magnification relative to Fit")
            Button { zoom = min(6, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in").disabled(zoom >= 6)
            Button("Fit") { zoom = 1 }.help("Fit the whole page in the viewer")
            Spacer()
            Text("Pinch to zoom · Scroll to pan").font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 7)
        .disabled(library.preview == nil)
      }
        .onChange(of: zoom) { _, _ in drag = nil; cropDrag = nil }
        .onChange(of: library.state.selection) { _, _ in zoom = 1; pinchStart = nil }
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
