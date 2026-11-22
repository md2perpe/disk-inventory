#if canImport(Darwin)
import XCTest
@testable import DiskInventoryCore

/// Checks the `getattrlistbulk` reader against what Foundation reports for the same files.
final class BulkReaderTests: XCTestCase {

    private struct Reference {
        var kind: RawEntry.Kind
        var logical: UInt64
        var physical: UInt64
        var isVolume: Bool
    }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isVolumeKey,
        .fileSizeKey, .totalFileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
    ]

    private func foundationEntries(in dir: String) throws -> [String: Reference] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: Self.keys, options: [])
        var result: [String: Reference] = [:]
        for url in urls {
            let v = try url.resourceValues(forKeys: Set(Self.keys))
            let kind: RawEntry.Kind
            if v.isSymbolicLink == true { kind = .symlink }
            else if v.isDirectory == true { kind = .directory }
            else if v.isRegularFile == true { kind = .file }
            else { kind = .other }
            let logical = v.totalFileSize ?? v.fileSize ?? 0
            let physical = v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? logical
            result[url.lastPathComponent] = Reference(
                kind: kind, logical: UInt64(max(0, logical)), physical: UInt64(max(0, physical)),
                isVolume: v.isVolume ?? false)
        }
        return result
    }

    /// Compares the readers directory by directory below `root` (at most `limit` entries).
    private func compare(root: String, limit: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        guard FileManager.default.fileExists(atPath: root) else { throw XCTSkip("\(root) doesn't exist") }
        let bulk = BulkDirectoryReader()
        var queue = [root]
        var compared = 0
        var mismatches: [String] = []
        var compressed = 0

        while let dir = queue.popLast(), compared < limit {
            guard let entries = try? bulk.readEntries(atPath: dir, parentDevice: 0),
                  let reference = try? foundationEntries(in: dir) else { continue }

            if Set(entries.map(\.name)) != Set(reference.keys) {
                mismatches.append("\(dir): different entries (\(entries.count) vs \(reference.count))")
            }
            for e in entries {
                guard let r = reference[e.name] else { continue }
                compared += 1
                if e.kind != r.kind {
                    mismatches.append("\(dir)/\(e.name): kind \(e.kind) vs \(r.kind)")
                } else if e.kind != .directory && (e.logicalSize != r.logical || e.physicalSize != r.physical) {
                    mismatches.append("\(dir)/\(e.name): size \(e.logicalSize)/\(e.physicalSize) vs \(r.logical)/\(r.physical)")
                } else if e.kind == .directory && e.isMountPoint != r.isVolume {
                    mismatches.append("\(dir)/\(e.name): mount point \(e.isMountPoint) vs isVolume \(r.isVolume)")
                }
                if e.kind == .file && e.physicalSize < e.logicalSize / 2 && e.logicalSize > 4096 { compressed += 1 }
                if e.kind == .directory && !e.isMountPoint { queue.append(dir + "/" + e.name) }
            }
        }
        print("compared \(compared) entries below \(root); \(compressed) files are much smaller on disk than their size; \(mismatches.count) mismatches")
        for m in mismatches.prefix(15) { print("  MISMATCH", m) }
        XCTAssertGreaterThan(compared, 100, file: file, line: line)
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) differences, first: \(mismatches.first ?? "")", file: file, line: line)
    }

    func testMatchesFoundationInUsr() throws {
        try compare(root: "/usr", limit: 40_000)
    }

    func testMatchesFoundationInSystemLibrary() throws {
        // contains many compressed files, where allocated size and size differ a lot
        try compare(root: "/System/Library/Frameworks", limit: 40_000)
    }

    func testMatchesFoundationInApplications() throws {
        try compare(root: "/Applications", limit: 40_000)
    }

    func testMountPointsAreRecognised() throws {
        let bulk = BulkDirectoryReader()
        for dir in ["/", "/System/Volumes", "/Volumes"] {
            guard let entries = try? bulk.readEntries(atPath: dir, parentDevice: 0),
                  let reference = try? foundationEntries(in: dir) else { continue }
            for e in entries where e.kind == .directory {
                XCTAssertEqual(e.isMountPoint, reference[e.name]?.isVolume, "\(dir)/\(e.name)")
            }
        }
    }

    func testBulkAndPosixReadersAgreeOnNamesAndSizes() throws {
        let dir = "/usr/lib"
        let bulk = try BulkDirectoryReader().readEntries(atPath: dir, parentDevice: 0)
        let posix = try POSIXDirectoryReader().readEntries(atPath: dir, parentDevice: 0)
        XCTAssertEqual(Set(bulk.map(\.name)), Set(posix.map(\.name)))
        let posixByName = Dictionary(uniqueKeysWithValues: posix.map { ($0.name, $0) })
        for e in bulk where e.kind == .file {
            XCTAssertEqual(e.kind, posixByName[e.name]?.kind)
            XCTAssertEqual(e.logicalSize, posixByName[e.name]?.logicalSize, e.name)
        }
    }

    func testScannerKindsMatchFoundationForCommonFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dix-kinds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.txt", "b.png", "c.pdf", "d.plist", "e.zip", "f.swift", "g", "h.dylib"] {
            try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent(name))
        }
        let root = try FolderScanner().scan(url: dir)
        for item in root.children {
            let type = try item.url.resourceValues(forKeys: [.contentTypeKey]).contentType
            // extension-based lookup must agree with the (content based) type Foundation reports
            XCTAssertEqual(item.kindName, type?.localizedDescription, item.name)
        }
    }
}
#endif
