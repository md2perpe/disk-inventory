import Foundation

/// Which attribute of an item is matched when searching the file list.
public enum SearchField: String, CaseIterable, Identifiable, Sendable {
    case all = "Everything"
    case name = "Name"
    case kind = "Kind"
    case path = "Path"

    public var id: String { rawValue }
}

public enum FSItemSearch {
    /// Items matching `text` (case and diacritics insensitive, all whitespace separated words must match).
    public static func filter(_ items: [FSItem], text: String, field: SearchField) -> [FSItem] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return items }

        return items.filter { item in
            let haystack: String
            switch field {
            case .name: haystack = item.name
            case .kind: haystack = item.kindName
            case .path: haystack = item.path
            case .all: haystack = item.name + "\n" + item.kindName + "\n" + item.path
            }
            return words.allSatisfy {
                haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}
