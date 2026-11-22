// treemap-demo: renders the contents of a folder as a cushion treemap into a PNG file.
//
//   swift run treemap-demo <folder> [width height [output.png]]
//
// Runs on macOS and Linux; useful to check scanning, layout and rendering without the GUI.

import Foundation
import DiskInventoryCore
import TreeMapKit

// MARK: - Minimal PNG writer (stored deflate blocks, no compression)

func crc32(_ data: [UInt8]) -> UInt32 {
    struct Table { static let t: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    } }
    var c: UInt32 = 0xFFFFFFFF
    for b in data { c = Table.t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
}

func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }

func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
    let td = Array(type.utf8) + body
    return be32(UInt32(body.count)) + td + be32(crc32(td))
}

func pngData(_ buffer: PixelBuffer) -> Data {
    var raw: [UInt8] = []
    raw.reserveCapacity((buffer.width * 4 + 1) * buffer.height)
    for y in 0..<buffer.height {
        raw.append(0)
        raw.append(contentsOf: buffer.bytes[(y * buffer.bytesPerRow)..<((y + 1) * buffer.bytesPerRow)])
    }
    var z: [UInt8] = [0x78, 0x01]
    var pos = 0
    while pos < raw.count {
        let n = min(65535, raw.count - pos)
        let last: UInt8 = pos + n >= raw.count ? 1 : 0
        z += [last, UInt8(n & 255), UInt8(n >> 8), UInt8(~n & 255), UInt8((~n >> 8) & 255)]
        z += raw[pos..<(pos + n)]
        pos += n
    }
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in raw { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
    z += be32((b << 16) | a)

    var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    out += chunk("IHDR", be32(UInt32(buffer.width)) + be32(UInt32(buffer.height)) + [8, 6, 0, 0, 0])
    out += chunk("IDAT", z)
    out += chunk("IEND", [])
    return Data(out)
}

// MARK: - Data source

struct FolderSource: TreeMapDataSource {
    func children(of item: FSItem) -> [FSItem]? { item.isFolder ? item.children : nil }
    func weight(of item: FSItem) -> UInt64 { item.size }
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
guard let folder = args.first else {
    print("usage: treemap-demo <folder> [width height [output.png]]")
    exit(1)
}
let width = args.count > 2 ? Int(args[1]) ?? 1000 : 1000
let height = args.count > 2 ? Int(args[2]) ?? 700 : 700
let output = args.count > 3 ? args[3] : "treemap.png"

let t0 = Date()
let scanner = FolderScanner()
let root: FSItem
do {
    root = try scanner.scan(url: URL(fileURLWithPath: folder))
} catch {
    print("scan failed: \(error.localizedDescription)")
    exit(2)
}
let t1 = Date()

// DEMO_TREE_DEPTH=2 prints the biggest items of the tree down to that depth (for debugging scans)
if let depthText = ProcessInfo.processInfo.environment["DEMO_TREE_DEPTH"], let maxDepth = Int(depthText) {
    func dump(_ item: FSItem, depth: Int) {
        let flags = (item.isSymbolicLink ? " [link]" : "") + (item.isPackage ? " [package]" : "")
        print(String(repeating: "  ", count: depth) + "\(item.name)  \(SizeFormatting.string(forBytes: item.size))  (\(item.children.count) children)\(flags)")
        guard depth < maxDepth else { return }
        // the biggest items, plus hidden items such as ".nofollow" whatever their size
        let shown = item.children.prefix(8) + item.children.dropFirst(8).filter { $0.name.hasPrefix(".") && $0.isDirectory }
        for child in shown { dump(child, depth: depth + 1) }
    }
    dump(root, depth: 0)
}

let colors = FileTypeColors()
let stats = FileKindStatistics.collect(from: root, isNode: { $0.isFolder })
colors.reserveColors(for: stats)

let cell = TreeMapLayout.layout(root: root, in: PixelRect(x: 0, y: 0, width: width, height: height), source: FolderSource())
let t2 = Date()
let image = CushionRenderer.render(root: cell, width: width, height: height) { colors.color(forKind: $0.kindName) }
let t3 = Date()

try pngData(image).write(to: URL(fileURLWithPath: output))

func ms(_ a: Date, _ b: Date) -> String { String(format: "%.0f ms", b.timeIntervalSince(a) * 1000) }
print("""
\(root.displayName): \(SizeFormatting.string(forBytes: root.size)) in \(root.deepFileCount(includingPackages: true)) files
scan \(ms(t0, t1)), layout \(ms(t1, t2)), render \(ms(t2, t3)) -> \(output)
top kinds:
""")
for s in stats.prefix(8) {
    print("  \(s.kindName.padding(toLength: 28, withPad: " ", startingAt: 0)) \(SizeFormatting.string(forBytes: s.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(s.fileCount) files")
}
