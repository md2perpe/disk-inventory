import AppKit
import SwiftUI
import DiskInventoryCore
import TreeMapKit

/// The cushion treemap. SwiftUI has no equivalent of a custom-drawn, hit-testable bitmap view,
/// so this is the one place where an `NSView` is wrapped.
struct TreeMapView: NSViewRepresentable {
    let session: FolderSession
    /// changes whenever the tree, the zoom or a view option changes
    let revision: Int
    let selection: FSItem?

    func makeNSView(context: Context) -> TreeMapNSView {
        TreeMapNSView(frame: .zero)
    }

    func updateNSView(_ view: TreeMapNSView, context: Context) {
        let session = self.session
        view.source = session.treeMapSource()
        view.colorProvider = { session.color(for: $0) }
        view.onSelect = { session.select($0) }
        view.onHover = { session.hoveredItem = $0 }
        view.menuProvider = { ItemMenu.make(for: $0, session: session) }
        view.revision = revision
        view.selectedItem = selection
    }
}

final class TreeMapNSView: NSView {
    // MARK: Configuration (set by the representable)

    var source: FSTreeMapSource?
    var colorProvider: (FSItem) -> RGB = { _ in RGB.defaultCushion }
    var onSelect: (FSItem?) -> Void = { _ in }
    var onHover: (FSItem?) -> Void = { _ in }
    var menuProvider: (FSItem) -> NSMenu? = { _ in nil }

    var revision = 0 {
        didSet {
            if revision != oldValue {
                cacheIsValid = false
                needsDisplay = true
            }
        }
    }

    var selectedItem: FSItem? {
        didSet {
            if selectedItem !== oldValue { needsDisplay = true }
        }
    }

    // MARK: Rendering cache

    private var rootCell: TreeMapCell<FSItem>?
    private var image: NSImage?
    private var cacheIsValid = false
    private var builtWidth = 0
    private var builtHeight = 0
    private var builtScale: CGFloat = 1
    private var hoveredCell: TreeMapCell<FSItem>?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Treemap of the folder contents")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        // While the window is being resized we just scale the last image (re-laying out a big tree is too slow)
        if inLiveResize {
            image?.draw(in: bounds, from: .zero, operation: .copy, fraction: 0.6, respectFlipped: true, hints: nil)
            return
        }

        rebuildIfNeeded()
        image?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        drawSelection()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        cacheIsValid = false
        needsDisplay = true
    }

    /// The layout and the cushions are computed in device pixels, so the treemap is sharp on Retina displays.
    private func rebuildIfNeeded() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())

        guard width > 0, height > 0, let source else {
            rootCell = nil
            image = nil
            return
        }
        if cacheIsValid && width == builtWidth && height == builtHeight && scale == builtScale { return }

        let cell = TreeMapLayout.layout(
            root: source.top,
            in: PixelRect(x: 0, y: 0, width: width, height: height),
            source: source,
            minimumCellSize: max(1, Int(scale)))
        let buffer = CushionRenderer.render(root: cell, width: width, height: height, color: colorProvider)

        rootCell = cell
        image = buffer.cgImage.map { NSImage(cgImage: $0, size: bounds.size) }
        builtWidth = width
        builtHeight = height
        builtScale = scale
        cacheIsValid = true
    }

    private func drawSelection() {
        guard let item = selectedItem, let rootCell, let source,
              let cell = rootCell.cell(forPath: item.pathFromAncestor(source.top))
        else { return }

        let s = builtScale
        let r = NSRect(x: CGFloat(cell.rect.x) / s, y: CGFloat(cell.rect.y) / s,
                       width: CGFloat(cell.rect.width) / s, height: CGFloat(cell.rect.height) / s)
        guard r.width >= 1, r.height >= 1 else { return }

        let path = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.systemYellow.setStroke()
        path.stroke()
    }

    // MARK: Mouse

    private func cell(at event: NSEvent) -> TreeMapCell<FSItem>? {
        let p = convert(event.locationInWindow, from: nil)
        return rootCell?.hitTest(x: Int(p.x * builtScale), y: Int(p.y * builtScale))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let item = cell(at: event)?.item
        onSelect((item?.isSpecialItem ?? true) ? nil : item)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.rightMouseDown(with: event)   // shows the menu from `menu(for:)`
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item = cell(at: event)?.item, !item.isSpecialItem else { return nil }
        // select what was clicked so it is clear which item the menu is for
        onSelect(item)
        return menuProvider(item)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let c = cell(at: event)
        if c !== hoveredCell {
            hoveredCell = c
            onHover(c?.item)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredCell != nil {
            hoveredCell = nil
            onHover(nil)
        }
    }
}
