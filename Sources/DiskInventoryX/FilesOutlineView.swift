import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DiskInventoryCore

/// The file tree (left side of the window): a standard `NSOutlineView` with name, size and share of the parent.
///
/// SwiftUI's `Table`/`List` cannot expand rows programmatically (needed to reveal the item selected in the
/// treemap), so this wraps the AppKit control.
struct FilesOutlineView: NSViewRepresentable {
    let session: FolderSession
    let revision: Int
    let selection: FSItem?
    let smallFont: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = ItemOutlineView()

        let name = NSTableColumn(identifier: Coordinator.nameColumn)
        name.title = "Name"
        name.minWidth = 140
        name.width = 260
        name.resizingMask = [.userResizingMask, .autoresizingMask]

        let size = NSTableColumn(identifier: Coordinator.sizeColumn)
        size.title = "Size"
        size.minWidth = 60
        size.width = 90
        size.resizingMask = .userResizingMask

        let percent = NSTableColumn(identifier: Coordinator.percentColumn)
        percent.title = "% of Parent"
        percent.minWidth = 70
        percent.width = 80
        percent.resizingMask = .userResizingMask

        for column in [name, size, percent] { outline.addTableColumn(column) }
        outline.outlineTableColumn = name
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.style = .fullWidth
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)   // drag files into other applications
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator

        let session = self.session
        outline.menuProvider = { ItemMenu.make(for: $0, session: session) }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(revision: revision, selection: selection, smallFont: smallFont)
    }

    // MARK: - Coordinator (data source and delegate)

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        static let nameColumn = NSUserInterfaceItemIdentifier("name")
        static let sizeColumn = NSUserInterfaceItemIdentifier("size")
        static let percentColumn = NSUserInterfaceItemIdentifier("percent")

        let session: FolderSession
        weak var outline: ItemOutlineView?

        private var top: FSItem?
        private var lastRevision = -1
        private var smallFont = false
        private var suppressSelectionNotification = false
        private var iconCache: [String: NSImage] = [:]

        init(session: FolderSession) {
            self.session = session
        }

        // MARK: Updating from SwiftUI

        func update(revision: Int, selection: FSItem?, smallFont: Bool) {
            guard let outline else { return }
            top = session.zoomedItem

            var reload = false
            if revision != lastRevision {
                lastRevision = revision
                reload = true
            }
            if smallFont != self.smallFont {
                self.smallFont = smallFont
                outline.rowSizeStyle = smallFont ? .small : .default
                reload = true
            }

            suppressSelectionNotification = true
            defer { suppressSelectionNotification = false }
            if reload { outline.reloadData() }
            reveal(selection)
        }

        /// Selects `item` in the outline, expanding its ancestors if necessary.
        private func reveal(_ item: FSItem?) {
            guard let outline else { return }

            let current = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? FSItem : nil
            if current === item { return }

            guard let item, let top else {
                outline.deselectAll(nil)
                return
            }
            let path = item.pathFromAncestor(top)      // top, ..., item
            guard path.first === top, path.count > 1 else {
                outline.deselectAll(nil)
                return
            }
            for ancestor in path.dropFirst().dropLast() {
                outline.expandItem(ancestor)
            }
            let row = outline.row(forItem: item)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            } else {
                outline.deselectAll(nil)
            }
        }

        // MARK: NSOutlineViewDataSource

        private func children(of item: Any?) -> [FSItem] {
            guard let item = item as? FSItem else { return top?.children ?? [] }
            return session.isNode(item) ? item.children : []
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(of: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? FSItem else { return false }
            return session.isNode(item) && !item.children.isEmpty
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let item = item as? FSItem, !item.isSpecialItem else { return nil }
            return item.url as NSURL
        }

        // MARK: NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? FSItem, let column = tableColumn else { return nil }
            let font = NSFont.systemFont(ofSize: smallFont ? NSFont.smallSystemFontSize : NSFont.systemFontSize)

            switch column.identifier {
            case Self.nameColumn:
                let cell = outlineView.makeView(withIdentifier: Self.nameColumn, owner: self) as? NameCellView
                    ?? NameCellView(identifier: Self.nameColumn)
                cell.textField?.stringValue = item.name
                cell.textField?.font = font
                cell.imageView?.image = icon(for: item)
                return cell

            case Self.sizeColumn:
                let cell = outlineView.makeView(withIdentifier: Self.sizeColumn, owner: self) as? TextCellView
                    ?? TextCellView(identifier: Self.sizeColumn, alignment: .right)
                cell.textField?.stringValue = SizeFormatting.string(forBytes: item.size)
                cell.textField?.font = font
                return cell

            case Self.percentColumn:
                let cell = outlineView.makeView(withIdentifier: Self.percentColumn, owner: self) as? TextCellView
                    ?? TextCellView(identifier: Self.percentColumn, alignment: .right)
                let parentSize = item.parent?.size ?? item.size
                cell.textField?.stringValue = parentSize == 0
                    ? "–" : SizeFormatting.percentString(Double(item.size) / Double(parentSize))
                cell.textField?.font = font
                return cell

            default:
                return nil
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionNotification, let outline else { return }
            let row = outline.selectedRow
            session.select(row >= 0 ? outline.item(atRow: row) as? FSItem : nil)
        }

        // MARK: Icons

        private func icon(for item: FSItem) -> NSImage {
            let key: String
            let make: () -> NSImage
            if item.isFolder || item.isSymbolicLink || item.isRoot {
                // folders, packages (applications have their own icons) and links: ask for the real file
                key = item.path
                make = { NSWorkspace.shared.icon(forFile: item.path) }
            } else {
                // regular files: the icon only depends on the file type
                let ext = (item.name as NSString).pathExtension.lowercased()
                key = "ext:" + ext
                make = {
                    let type = UTType(filenameExtension: ext) ?? .data
                    return NSWorkspace.shared.icon(for: type)
                }
            }
            if let cached = iconCache[key] { return cached }
            let image = (make().copy() as? NSImage) ?? make()
            image.size = NSSize(width: 16, height: 16)
            iconCache[key] = image
            return image
        }
    }
}

// MARK: - AppKit helpers

/// An outline view that shows a context menu for the row under the pointer (and selects that row).
final class ItemOutlineView: NSOutlineView {
    var menuProvider: ((FSItem) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let item = self.item(atRow: row) as? FSItem else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return menuProvider?(item)
    }
}

/// Cell with icon and file name.
final class NameCellView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Cell with a single line of text.
final class TextCellView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) {
        super.init(frame: .zero)
        self.identifier = identifier

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
