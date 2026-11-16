import SwiftUI
import AppKit

/// AppKit supplies range selection, drag images, insertion feedback and autoscroll.
struct PageList: NSViewRepresentable {
    @EnvironmentObject var library: Library

    func makeCoordinator() -> Coordinator { Coordinator(library) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = PageTable()
        table.addTableColumn(NSTableColumn(identifier: .init("pages")))
        table.headerView = nil
        table.rowHeight = 66
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.style = .sourceList
        table.backgroundColor = .clear
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([Coordinator.pageType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        context.coordinator.table = table
        table.moveSelection = { [weak table, weak coordinator = context.coordinator] direction in
            guard let coordinator, let table else { return }
            coordinator.library.moveSelectedPages(by: direction)
            coordinator.update(coordinator.library)
            let rows = table.selectedRowIndexes
            if let row = direction < 0 ? rows.first : rows.last { table.scrollRowToVisible(row) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(library)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let pageType = NSPasteboard.PasteboardType("com.scancleaner.page")
        var library: Library
        weak var table: NSTableView?
        var pages: [ScanPage] = []
        var updating = false
        var dragIDs: Set<UUID> = []
        init(_ library: Library) { self.library = library }

        func update(_ library: Library) {
            guard let table else { return }
            self.library = library
            updating = true
            let changed = pages.map(\.id) != library.state.pages.map(\.id)
            pages = library.state.pages
            if changed { table.reloadData() }
            else {
                for row in table.rows(in: table.visibleRect).location..<NSMaxRange(table.rows(in: table.visibleRect)) where pages.indices.contains(row) {
                    if let host = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSHostingView<PageListRow> {
                        host.rootView = PageListRow(page: pages[row], number: row + 1, library: library)
                    }
                }
            }
            let selected = IndexSet(pages.indices.filter { library.selectedPageIDs.contains(pages[$0].id) })
            if table.selectedRowIndexes != selected {
                table.selectRowIndexes(selected, byExtendingSelection: false)
                if selected.count == 1, let row = selected.first { table.scrollRowToVisible(row) }
            }
            updating = false
        }
        func numberOfRows(in tableView: NSTableView) -> Int { pages.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("pageRow")
            let content = PageListRow(page: pages[row], number: row + 1, library: library)
            if let host = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSHostingView<PageListRow> {
                host.rootView = content
                return host
            }
            let host = NSHostingView(rootView: content)
            host.identifier = identifier
            return host
        }
        func selectionShouldChange(in tableView: NSTableView) -> Bool { !library.busy }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            library.selectPages(Set(table.selectedRowIndexes.compactMap { pages.indices.contains($0) ? pages[$0].id : nil }))
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard !library.busy else { return nil }
            let item = NSPasteboardItem()
            item.setString(pages[row].id.uuidString, forType: Self.pageType)
            return item
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            dragIDs = Set(rowIndexes.map { pages[$0].id })
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard !library.busy, info.draggingSource as? NSTableView === tableView else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard !library.busy, info.draggingSource as? NSTableView === tableView, !dragIDs.isEmpty else { return false }
            let offsets = IndexSet(library.state.pages.indices.filter { dragIDs.contains(library.state.pages[$0].id) })
            library.movePages(from: offsets, to: row)
            library.selectPages(dragIDs)
            return true
        }
    }
}

private struct PageListRow: View {
    let page: ScanPage
    let number: Int
    @ObservedObject var library: Library
    var body: some View {
        HStack(spacing: 9) {
            PageThumbnail(page: page).environmentObject(library).id(page.id)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("Page \(number)").fontWeight(.medium)
                    if page.reviewed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done") }
                }
                Text(page.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private final class PageTable: NSTableView {
    var moveSelection: ((Int) -> Void)?
    private var lastAutoscrollTime: TimeInterval = 0

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if modifiers == .control, event.keyCode == 126 || event.keyCode == 125 {
            moveSelection?(event.keyCode == 126 ? -1 : 1)
            return
        }
        super.keyDown(with: event)
    }

    override func autoscroll(with event: NSEvent) -> Bool {
        guard let scroll = enclosingScrollView else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let visible = visibleRect
        let edge: CGFloat = 24
        let direction: CGFloat
        if point.y < visible.minY + edge { direction = -1 }
        else if point.y > visible.maxY - edge { direction = 1 }
        else { lastAutoscrollTime = 0; return false }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastAutoscrollTime == 0 ? 1.0 / 30 : min(now - lastAutoscrollTime, 0.05)
        lastAutoscrollTime = now
        let y = min(max(visible.minY + direction * 100 * elapsed, 0), max(0, bounds.height - visible.height))
        guard y != visible.minY else { return false }
        scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click is an additive selection gesture here, just like Command-click.
        if event.modifierFlags.contains(.control), let mapped = NSEvent.mouseEvent(
            with: event.type, location: event.locationInWindow,
            modifierFlags: event.modifierFlags.subtracting(.control).union(.command),
            timestamp: event.timestamp, windowNumber: event.windowNumber,
            context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure
        ) { super.mouseDown(with: mapped) }
        else { super.mouseDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}
