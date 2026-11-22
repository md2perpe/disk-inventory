import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Finds the "kind" shown for files ("PDF document", "Folder", ...).
///
/// The kind of a regular file is derived from its file name extension, which only has to be looked up
/// once per extension instead of once per file. Thread safe.
final class KindResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var byKey: [String: String] = [:]

    static func fileExtension(of name: String) -> String {
        let utf8 = name.utf8
        guard let dot = utf8.lastIndex(of: UInt8(ascii: ".")) else { return "" }
        // ".hidden" and "name." have no extension
        if dot == utf8.startIndex || utf8.index(after: dot) == utf8.endIndex { return "" }
        return String(name[utf8.index(after: dot)...]).lowercased()
    }

    /// - Parameter local: a cache owned by the caller (e.g. one folder), consulted before the shared one
    func kind(forFileNamed name: String, isExecutable: Bool, local: inout [String: String]) -> String {
        let ext = Self.fileExtension(of: name)
        let key = ext.isEmpty ? (isExecutable ? "\u{1}executable" : "\u{1}none") : ext
        if let cached = local[key] { return cached }
        let kind = sharedKind(forKey: key, ext: ext, isExecutable: isExecutable)
        local[key] = kind
        return kind
    }

    var folderKind: String { shared("\u{1}folder") { Self.describeFolder() } }
    var symlinkKind: String { shared("\u{1}symlink") { Self.describeSymlink() } }

    // MARK: -

    private func sharedKind(forKey key: String, ext: String, isExecutable: Bool) -> String {
        shared(key) { Self.describe(extension: ext, isExecutable: isExecutable) }
    }

    private func shared(_ key: String, compute: () -> String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = byKey[key] { return cached }
        let value = compute()
        byKey[key] = value
        return value
    }

    #if canImport(UniformTypeIdentifiers)

    private static func describe(extension ext: String, isExecutable: Bool) -> String {
        if ext.isEmpty {
            return (isExecutable ? UTType.unixExecutable : UTType.data).localizedDescription ?? "Document"
        }
        return UTType(filenameExtension: ext)?.localizedDescription ?? "Document"
    }
    private static func describeFolder() -> String { UTType.folder.localizedDescription ?? "Folder" }
    private static func describeSymlink() -> String { UTType.symbolicLink.localizedDescription ?? "Symbolic link" }

    #else

    private static func describe(extension ext: String, isExecutable: Bool) -> String {
        ext.isEmpty ? "Document" : "\(ext.uppercased()) document"
    }
    private static func describeFolder() -> String { "Folder" }
    private static func describeSymlink() -> String { "Symbolic link" }

    #endif

    /// Whether a directory is a package (e.g. an application) and its kind. Only meaningful on macOS.
    static func packageInfo(atPath path: String) -> (isPackage: Bool, kind: String?) {
        #if canImport(UniformTypeIdentifiers)
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey, .contentTypeKey])
        return (values?.isPackage ?? false, values?.contentType?.localizedDescription)
        #else
        return (false, nil)
        #endif
    }
}
