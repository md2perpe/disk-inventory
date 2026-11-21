import Foundation
import TreeMapKit

/// Assigns a cushion colour to every file kind.
///
/// The first twelve kinds (colours are handed out in the order of first use; callers should request them
/// for the biggest kinds first) get bright, well distinguishable colours. All further kinds get shades of gray.
public final class FileTypeColors {
    /// Colours shared by all windows (used when "share colours between windows" is on).
    public static let shared = FileTypeColors()

    private static let predefined: [RGB] = [
        RGB(r: 0, g: 0, b: 1),
        RGB(r: 1, g: 0, b: 0),
        RGB(r: 0, g: 1, b: 0),
        RGB(r: 0, g: 1, b: 1),
        RGB(r: 1, g: 0, b: 1),
        RGB(r: 1, g: 1, b: 0),
        RGB(r: 0.58, g: 0.58, b: 1),
        RGB(r: 1, g: 0.58, b: 0.58),
        RGB(r: 0.58, g: 1, b: 0.58),
        RGB(r: 0.58, g: 1, b: 1),
        RGB(r: 1, g: 0.58, b: 1),
        RGB(r: 1, g: 1, b: 0.58),
    ].map { $0.normalized }

    private var colors: [String: RGB] = [:]
    private let lock = NSLock()

    public init() {}

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        colors.removeAll()
    }

    public func color(forKind kind: String) -> RGB {
        lock.lock(); defer { lock.unlock() }
        if let c = colors[kind] { return c }

        let color: RGB
        if colors.count < FileTypeColors.predefined.count {
            color = FileTypeColors.predefined[colors.count]
        } else {
            let gray = min(0.9, Double(colors.count) * 0.05)
            color = RGB(r: gray, g: gray, b: gray).normalized
        }
        colors[kind] = color
        return color
    }

    /// Makes sure the biggest kinds get the predefined colours.
    public func reserveColors(for statistics: [FileKindStatistic]) {
        for s in statistics.sorted(by: { $0.size > $1.size }) { _ = color(forKind: s.kindName) }
    }

    /// Colours of the pseudo items shown in the treemap.
    public static let freeSpaceColor = RGB(r: 1, g: 1, b: 1).normalized
    public static let otherSpaceColor = RGB(r: 0.2, g: 0.2, b: 0.2).normalized
}
