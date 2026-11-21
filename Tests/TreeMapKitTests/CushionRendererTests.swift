import XCTest
@testable import TreeMapKit

final class CushionRendererTests: XCTestCase {

    func testNormalizedColorHasBaseBrightness() {
        for c in [RGB(r: 0, g: 0, b: 0.9), RGB(r: 0.2, g: 0.2, b: 0.2), RGB(r: 0.3, g: 0.5, b: 0.1), RGB(r: 0, g: 0, b: 1)] {
            let n = c.normalized
            XCTAssertEqual(n.r + n.g + n.b, RGB.baseBrightness, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(max(n.r, n.g, n.b), 1.0 + 1e-12)
        }
    }

    func testNormalizingPureColorsRedistributesOverflow() {
        // (0,0,1) * 1.8 = (0,0,1.8) -> blue clamps to 1, the excess 0.8 is split between red and green
        let n = RGB(r: 0, g: 0, b: 1).normalized
        XCTAssertEqual(n.b, 1, accuracy: 1e-12)
        XCTAssertEqual(n.r, 0.4, accuracy: 1e-12)
        XCTAssertEqual(n.g, 0.4, accuracy: 1e-12)
    }

    func testBlackNormalizesToNeutralGray() {
        let n = RGB(r: 0, g: 0, b: 0).normalized
        XCTAssertEqual(n, RGB(r: 0, g: 0, b: 0))   // factor falls back to 1, stays black
    }

    func testSwatchIsBrightestNearTopLeftOfCentreAndDarkAtEdges() {
        let img = CushionRenderer.renderSwatch(width: 60, height: 40, color: RGB(r: 1, g: 1, b: 1).normalized)
        func lum(_ x: Int, _ y: Int) -> Int {
            let i = y * img.bytesPerRow + x * 4
            return Int(img.bytes[i]) + Int(img.bytes[i + 1]) + Int(img.bytes[i + 2])
        }
        // light comes from the top left, so the lit region is up-left of the centre
        XCTAssertGreaterThan(lum(27, 17), lum(30, 20) - 1)
        XCTAssertGreaterThan(lum(27, 17), lum(0, 39))
        XCTAssertGreaterThan(lum(27, 17), lum(59, 39))
        XCTAssertGreaterThan(lum(27, 17), lum(59, 0))
        // every pixel is opaque
        for p in stride(from: 3, to: img.bytes.count, by: 4) { XCTAssertEqual(img.bytes[p], 255) }
    }

    func testRenderPaintsEveryPixelOfLeaves() {
        let kids = (0..<20).map { Node(weight: UInt64(100 - $0 * 4)) }
        let cell = TreeMapLayout.layout(root: Node(children: kids), in: PixelRect(x: 0, y: 0, width: 160, height: 90), source: NodeSource())
        let bg = RGB(r: 0, g: 0, b: 0)
        let img = CushionRenderer.render(root: cell, width: 160, height: 90, background: bg) { _ in RGB(r: 1, g: 1, b: 1).normalized }
        var dark = 0
        for p in stride(from: 0, to: img.bytes.count, by: 4) where img.bytes[p] == 0 && img.bytes[p + 1] == 0 && img.bytes[p + 2] == 0 { dark += 1 }
        XCTAssertEqual(dark, 0, "no pixel may keep the background colour when leaves tile the whole image")
    }

    func testNodesWithoutLeavesAreNotPainted() {
        // a folder containing only empty folders has nothing to draw: the background must stay untouched
        let root = Node(children: [Node(children: []), Node(children: [])])
        let cell = TreeMapLayout.layout(root: root, in: PixelRect(x: 0, y: 0, width: 20, height: 20), source: NodeSource())
        let img = CushionRenderer.render(root: cell, width: 20, height: 20, background: RGB(r: 1, g: 0, b: 0)) { _ in RGB.defaultCushion }
        for p in stride(from: 0, to: img.bytes.count, by: 4) {
            XCTAssertEqual([img.bytes[p], img.bytes[p + 1], img.bytes[p + 2], img.bytes[p + 3]], [255, 0, 0, 255])
        }
    }

    func testRenderingIsDeterministicAcrossThreads() {
        // > 8 leaves per batch triggers the concurrent code path; results must not depend on scheduling
        var rng = LCG(state: 5)
        let kids = (0..<2000).map { _ in Node(weight: UInt64.random(in: 1...100_000, using: &rng)) }.sorted { $0.weight > $1.weight }
        let cell = TreeMapLayout.layout(root: Node(children: kids), in: PixelRect(x: 0, y: 0, width: 400, height: 300), source: NodeSource())
        let color: (Node) -> RGB = { n in RGB(r: Double(n.leafWeight % 7) / 7, g: 0.5, b: 0.2).normalized }
        let a = CushionRenderer.render(root: cell, width: 400, height: 300, color: color)
        let b = CushionRenderer.render(root: cell, width: 400, height: 300, color: color)
        XCTAssertEqual(a.bytes, b.bytes)
    }

    func testSingleLeafMatchesManualSurface() {
        // root -> one leaf covering everything: the leaf gets one ridge of height 0.5 * 0.9
        let root = Node(children: [Node(weight: 10)])
        let rect = PixelRect(x: 0, y: 0, width: 30, height: 20)
        let cell = TreeMapLayout.layout(root: root, in: rect, source: NodeSource())
        let color = RGB(r: 0.5, g: 0.2, b: 0.9).normalized
        let img = CushionRenderer.render(root: cell, width: 30, height: 20) { _ in color }

        var s = CushionSurface()
        s.addRidge(height: CushionRenderer.initialHeightFactor * CushionRenderer.scaleFactor, rect: rect)
        XCTAssertEqual(s.s0, -4 * 0.45 / 30, accuracy: 1e-12)
        XCTAssertEqual(s.s2, 4 * 0.45 / 30 * 30, accuracy: 1e-12)

        // surface normal at centre pixel (14.5, 9.5 -> ix=14, iy=9)
        let nx = -(2 * s.s0 * 14.5 + s.s2), ny = -(2 * s.s1 * 9.5 + s.s3)
        let Lx = -1 / 102.0.squareRoot(), Ly = Lx, Lz = 10 / 102.0.squareRoot()
        var br = 0.85 * ((nx * Lx + ny * Ly + Lz) / (nx * nx + ny * ny + 1).squareRoot())
        br = br < 0 ? 0.15 : br + 0.15
        br *= 2.5 / 1.8
        var r = color.r * br, g = color.g * br, b = color.b * br
        RGB.clamp(&r, &g, &b)
        let i = 9 * img.bytesPerRow + 14 * 4
        XCTAssertEqual(Int(img.bytes[i]), Int(r * 255), accuracy: 1)
        XCTAssertEqual(Int(img.bytes[i + 1]), Int(g * 255), accuracy: 1)
        XCTAssertEqual(Int(img.bytes[i + 2]), Int(b * 255), accuracy: 1)
    }

    func testZeroSizeRenderDoesNotCrash() {
        let cell = TreeMapLayout.layout(root: Node(weight: 1), in: PixelRect(x: 0, y: 0, width: 0, height: 0), source: NodeSource())
        let img = CushionRenderer.render(root: cell, width: 0, height: 0) { _ in RGB.defaultCushion }
        XCTAssertEqual(img.bytes.count, 0)
    }
}
