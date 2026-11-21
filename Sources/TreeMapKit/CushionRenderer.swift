import Dispatch

/// An RGBA, 8 bits per channel, row-major pixel buffer (alpha is always 255).
public struct PixelBuffer: Sendable {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public var bytesPerRow: Int { width * 4 }

    public init(width: Int, height: Int, fill: RGB = RGB(r: 0.12, g: 0.12, b: 0.12)) {
        self.width = max(0, width)
        self.height = max(0, height)
        let r = UInt8(max(0, min(255, fill.r * 255)))
        let g = UInt8(max(0, min(255, fill.g * 255)))
        let b = UInt8(max(0, min(255, fill.b * 255)))
        var bytes = [UInt8](repeating: 255, count: self.width * self.height * 4)
        bytes.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                p[i] = r
                p[i + 1] = g
                p[i + 2] = b
                i += 4
            }
        }
        self.bytes = bytes
    }
}

/// The parabolic "cushion" surface of a treemap cell (van Wijk & van de Wetering, "Cushion Treemaps").
///
/// The surface is `z(x, y) = s0 x² + s1 y² + s2 x + s3 y`. Every level of the tree adds a ridge (a parabola
/// over the cell's rectangle) whose height decreases with the nesting depth.
public struct CushionSurface: Sendable {
    public var s0 = 0.0
    public var s1 = 0.0
    public var s2 = 0.0
    public var s3 = 0.0

    public init() {}

    /// Adds a ridge over `rect`. `rect` must not be empty.
    public mutating func addRidge(height h: Double, rect: PixelRect) {
        let h4 = 4 * h
        let wf = h4 / Double(rect.width)
        s2 += wf * Double(rect.maxX + rect.x)
        s0 -= wf
        let hf = h4 / Double(rect.height)
        s3 += hf * Double(rect.maxY + rect.y)
        s1 -= hf
    }
}

/// Renders cushion shaded treemaps into pixel buffers.
public enum CushionRenderer {
    /// Height of the first ridge; every nesting level scales it by `scaleFactor`.
    public static let initialHeightFactor = 0.5
    public static let scaleFactor = 0.9

    // Illumination model
    private static let ambient = 0.15            // Ia
    private static let lightX = -1.0             // negative = from the left
    private static let lightY = -1.0             // negative = from the top
    private static let lightZ = 10.0

    struct Job {
        var rect: PixelRect
        var surface: CushionSurface
        var color: RGB
    }

    /// Renders all leaves of `root`.
    ///
    /// - Parameters:
    ///   - root: laid out tree (see `TreeMapLayout`)
    ///   - color: colour for a leaf; should be `normalized`
    public static func render<Item: AnyObject>(
        root: TreeMapCell<Item>,
        width: Int,
        height: Int,
        background: RGB = RGB(r: 0.12, g: 0.12, b: 0.12),
        color: (Item) -> RGB
    ) -> PixelBuffer {
        var buffer = PixelBuffer(width: width, height: height, fill: background)
        guard width > 0, height > 0 else { return buffer }

        let batchSize = 4096
        var batch: [Job] = []
        batch.reserveCapacity(batchSize)

        buffer.bytes.withUnsafeMutableBufferPointer { pixels in
            guard let base = pixels.baseAddress else { return }
            let stride = width * 4

            func flush() {
                guard !batch.isEmpty else { return }
                renderBatch(batch, base: base, stride: stride, width: width, height: height)
                batch.removeAll(keepingCapacity: true)
            }

            func collect(_ cell: TreeMapCell<Item>, parent: CushionSurface, heightFactor: Double, isRoot: Bool) {
                if cell.rect.isEmpty { return }
                var surface = parent
                if !isRoot { surface.addRidge(height: heightFactor, rect: cell.rect) }

                if cell.isLeaf {
                    batch.append(Job(rect: cell.rect, surface: surface, color: color(cell.item)))
                    if batch.count >= batchSize { flush() }
                } else {
                    for child in cell.children {
                        collect(child, parent: surface, heightFactor: heightFactor * scaleFactor, isRoot: false)
                    }
                }
            }

            collect(root, parent: CushionSurface(), heightFactor: initialHeightFactor, isRoot: true)
            flush()
        }
        return buffer
    }

    /// A single cushion filling a `width`×`height` image (used for the colour swatches of the kind statistics).
    public static func renderSwatch(width: Int, height: Int, color: RGB) -> PixelBuffer {
        var buffer = PixelBuffer(width: width, height: height)
        guard width > 0, height > 0 else { return buffer }
        var surface = CushionSurface()
        let rect = PixelRect(x: 0, y: 0, width: width, height: height)
        surface.addRidge(height: initialHeightFactor, rect: rect)
        buffer.bytes.withUnsafeMutableBufferPointer { pixels in
            renderJob(Job(rect: rect, surface: surface, color: color), base: pixels.baseAddress!, stride: width * 4)
        }
        return buffer
    }

    // MARK: - Pixel loops

    private static func renderBatch(
        _ jobs: [Job], base: UnsafeMutablePointer<UInt8>, stride: Int, width: Int, height: Int
    ) {
        // leaves cover disjoint pixels, so they can be rendered concurrently
        if jobs.count < 8 {
            for job in jobs { renderJob(job, base: base, stride: stride) }
            return
        }
        let chunks = min(jobs.count, 16)
        let per = (jobs.count + chunks - 1) / chunks
        jobs.withUnsafeBufferPointer { jp in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * per
                let hi = min(jp.count, lo + per)
                if lo >= hi { return }
                for k in lo..<hi { renderJob(jp[k], base: base, stride: stride) }
            }
        }
    }

    private static func renderJob(_ job: Job, base: UnsafeMutablePointer<UInt8>, stride: Int) {
        let Ia = ambient
        let Is = 1 - Ia
        let len = (lightX * lightX + lightY * lightY + lightZ * lightZ).squareRoot()
        let Lx = lightX / len
        let Ly = lightY / len
        let Lz = lightZ / len
        let brightnessScale = 2.5 / RGB.baseBrightness

        let s = job.surface
        let colR = job.color.r, colG = job.color.g, colB = job.color.b
        let rect = job.rect

        for iy in rect.y..<rect.maxY {
            let row = base + iy * stride
            let ny = -(2 * s.s1 * (Double(iy) + 0.5) + s.s3)

            for ix in rect.x..<rect.maxX {
                let nx = -(2 * s.s0 * (Double(ix) + 0.5) + s.s2)

                let cosa = (nx * Lx + ny * Ly + Lz) / (nx * nx + ny * ny + 1.0).squareRoot()
                var brightness = Is * cosa
                brightness = brightness < 0 ? Ia : brightness + Ia
                brightness *= brightnessScale

                var r = colR * brightness
                var g = colG * brightness
                var b = colB * brightness
                RGB.clamp(&r, &g, &b)

                let p = row + ix * 4
                p[0] = UInt8(max(0, min(255, r * 255)))
                p[1] = UInt8(max(0, min(255, g * 255)))
                p[2] = UInt8(max(0, min(255, b * 255)))
                p[3] = 255
            }
        }
    }
}
