/// An integer rectangle in pixel coordinates (origin top-left, y grows downwards).
///
/// The treemap works on whole pixels so that neighbouring cells tile perfectly without gaps or overlaps.
public struct PixelRect: Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(x px: Int, y py: Int) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }
}
