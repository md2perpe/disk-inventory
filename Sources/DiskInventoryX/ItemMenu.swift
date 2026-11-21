import AppKit
import DiskInventoryCore

/// A menu item that runs a closure (so menus can be built without a responder chain).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() { handler() }
}

/// The context menu shown for a file or folder in the outline and in the treemap.
@MainActor
enum ItemMenu {
    static func make(for item: FSItem, session: FolderSession) -> NSMenu? {
        guard !item.isSpecialItem else { return nil }
        let url = item.url
        let menu = NSMenu()

        menu.addItem(ClosureMenuItem(title: "Open", symbol: "arrow.up.forward.app") {
            NSWorkspace.shared.open(url)
        })
        menu.addItem(openWithItem(for: url))
        menu.addItem(ClosureMenuItem(title: "Show in Finder", symbol: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        menu.addItem(ClosureMenuItem(title: "Copy Path", symbol: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        })
        menu.addItem(.separator())

        if item.isFolder && item !== session.zoomedItem {
            menu.addItem(ClosureMenuItem(title: "Zoom In", symbol: "plus.magnifyingglass") {
                session.select(item)
                session.zoomIn()
            })
        }
        menu.addItem(ClosureMenuItem(title: "Refresh", symbol: "arrow.clockwise") {
            Task { await session.refresh(item) }
        })

        if session.canTrash(item) {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Move to Trash", symbol: "trash") {
                session.requestTrash(item)
            })
        }
        return menu
    }

    private static func openWithItem(for url: URL) -> NSMenuItem {
        let parent = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let workspace = NSWorkspace.shared

        let apps = workspace.urlsForApplications(toOpen: url)
        let defaultApp = workspace.urlForApplication(toOpen: url)

        for app in apps {
            var title = FileManager.default.displayName(atPath: app.path)
            if app == defaultApp { title += " (default)" }
            let entry = ClosureMenuItem(title: title) {
                workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
            // copy: the image returned by NSWorkspace may be shared
            if let icon = workspace.icon(forFile: app.path).copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
            }
            submenu.addItem(entry)
        }
        if apps.isEmpty {
            let none = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        parent.submenu = submenu
        return parent
    }
}
