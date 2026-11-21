/// A simple RGB colour with components in 0...1.
///
/// Cushion treemaps need every colour to have (roughly) the same perceived brightness, otherwise bright
/// colours would wash out the shading. `normalized` scales a colour to `baseBrightness` and redistributes
/// any overflow of a channel onto the other channels (the approach known from SequoiaView / WinDirStat).
public struct RGB: Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Brightness (sum of the three channels, 0...3) every cushion colour is normalised to.
    public static let baseBrightness = 1.8

    /// The colour a cushion has when nothing else was specified.
    public static let defaultCushion = RGB(r: 0, g: 0, b: 0.9).normalized

    public var normalized: RGB {
        let sum = r + g + b
        let f = sum != 0 ? RGB.baseBrightness / sum : 1
        var (nr, ng, nb) = (r * f, g * f, b * f)
        RGB.clamp(&nr, &ng, &nb)
        return RGB(r: nr, g: ng, b: nb)
    }

    /// Makes sure no channel exceeds 1.0 by moving the excess to the other two channels.
    @inline(__always)
    static func clamp(_ r: inout Double, _ g: inout Double, _ b: inout Double) {
        if r > 1 {
            distribute(&r, &g, &b)
        } else if g > 1 {
            distribute(&g, &r, &b)
        } else if b > 1 {
            distribute(&b, &r, &g)
        }
    }

    @inline(__always)
    private static func distribute(_ first: inout Double, _ second: inout Double, _ third: inout Double) {
        var h = (first - 1) / 2
        first = 1
        second += h
        third += h
        if second > 1 {
            h = second - 1
            second = 1
            third += h
        } else if third > 1 {
            h = third - 1
            third = 1
            second += h
        }
    }
}
