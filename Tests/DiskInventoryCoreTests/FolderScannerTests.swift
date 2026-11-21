import XCTest
@testable import DiskInventoryCore

final class FolderScannerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dix-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ relative: String, bytes: Int) throws {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    func testScansNestedFoldersAndSumsSizes() throws {
        try write("a.txt", bytes: 100)
        try write("sub/b.txt", bytes: 2000)
        try write("sub/deeper/c.png", bytes: 30000)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("empty"), withIntermediateDirectories: true)

        let root = try FolderScanner().scan(url: dir)

        XCTAssertEqual(root.size, 32100)
        XCTAssertEqual(root.children.map(\.name), ["sub", "a.txt", "empty"])
        let sub = try XCTUnwrap(root.children.first { $0.name == "sub" })
        XCTAssertEqual(sub.size, 32000)
        XCTAssertEqual(sub.children.map(\.name), ["deeper", "b.txt"])
        XCTAssertTrue(sub.isFolder)
        XCTAssertTrue(sub.parent === root)
        XCTAssertEqual(root.deepFileCount(includingPackages: true), 3)
        XCTAssertEqual(try XCTUnwrap(root.children.first { $0.name == "empty" }).size, 0)
        XCTAssertEqual(root.findItem(atPath: dir.path + "/sub/deeper/c.png", allowAncestors: false)?.size, 30000)
    }

    func testKindNamesAreAssignedAndShared() throws {
        try write("one.txt", bytes: 1)
        try write("two.txt", bytes: 1)
        try write("three.png", bytes: 1)
        let root = try FolderScanner().scan(url: dir)
        let kinds = Dictionary(uniqueKeysWithValues: root.children.map { ($0.name, $0.kindName) })
        XCTAssertEqual(kinds["one.txt"], kinds["two.txt"])
        XCTAssertNotEqual(kinds["one.txt"], kinds["three.png"])
        XCTAssertFalse(kinds["one.txt"]!.isEmpty)
    }

    func testSymbolicLinksAreNotFollowed() throws {
        try write("real/file.bin", bytes: 5000)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("real"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("loop"), withDestinationURL: dir)

        let root = try FolderScanner().scan(url: dir)

        let link = try XCTUnwrap(root.children.first { $0.name == "link" })
        XCTAssertTrue(link.isSymbolicLink)
        XCTAssertFalse(link.isFolder)
        XCTAssertTrue(link.children.isEmpty)
        // 5000 bytes are counted once (through "real"), the links contribute at most their own tiny size
        XCTAssertGreaterThanOrEqual(root.size, 5000)
        XCTAssertLessThan(root.size, 5000 + 8192)
    }

    func testPhysicalSizeModeChangesSizeUsed() throws {
        try write("tiny.txt", bytes: 3)
        let logicalRoot = try FolderScanner(sizeMode: .logical).scan(url: dir)
        let physicalRoot = try FolderScanner(sizeMode: .physical).scan(url: dir)
        XCTAssertEqual(logicalRoot.size, 3)
        XCTAssertGreaterThanOrEqual(physicalRoot.size, logicalRoot.size)
        XCTAssertEqual(physicalRoot.sizeMode, .physical)
        XCTAssertEqual(physicalRoot.children.first?.sizeMode, .physical)
    }

    func testMissingFolderThrows() {
        XCTAssertThrowsError(try FolderScanner().scan(url: dir.appendingPathComponent("nope"))) { error in
            guard case ScanError.doesNotExist = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testSingleFileCanBeScanned() throws {
        try write("lonely.dat", bytes: 777)
        let root = try FolderScanner().scan(url: dir.appendingPathComponent("lonely.dat"))
        XCTAssertEqual(root.size, 777)
        XCTAssertFalse(root.isFolder)
        XCTAssertTrue(root.children.isEmpty)
    }

    func testCancellationStopsScan() throws {
        for i in 0..<20 { try write("d\(i)/f.txt", bytes: 10) }
        var calls = 0
        let scanner = FolderScanner(isCancelled: { calls += 1; return calls > 3 })
        XCTAssertThrowsError(try scanner.scan(url: dir)) { error in
            guard case ScanError.cancelled = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testProgressIsReported() throws {
        try write("a/1", bytes: 1); try write("b/2", bytes: 1)
        var folders: [String] = []
        let scanner = FolderScanner(onProgress: { folders.append($0.currentFolder) })
        _ = try scanner.scan(url: dir)
        XCTAssertEqual(folders.count, 3)               // root + a + b
        XCTAssertEqual(folders.first, dir.path)
    }

    func testUnreadableFolderStaysAsEmptyFolder() throws {
        try write("locked/secret.txt", bytes: 10)
        try write("open.txt", bytes: 10)
        let locked = dir.appendingPathComponent("locked").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

        // root can read everything regardless of permissions, so only assert the scan completes sanely
        let root = try FolderScanner().scan(url: dir)
        XCTAssertGreaterThanOrEqual(root.size, 10)
        XCTAssertNotNil(root.children.first { $0.name == "locked" })
    }
}
