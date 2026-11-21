import SwiftUI
import AppKit
import DiskInventoryCore
import TreeMapKit

enum InspectorTab: String, CaseIterable, Identifiable {
    case kinds = "Kinds"
    case files = "Files"
    case info = "Info"
    var id: String { rawValue }
}

/// The trailing inspector: file kind statistics, a searchable list of files and details of the selected item.
/// (Replaces the two drawers and the info panel of the original application.)
struct InspectorView: View {
    let session: FolderSession
    @Binding var tab: InspectorTab
    /// kind shown in the file list (nil = all kinds); shared so the kinds tab can jump to the list
    @State private var listKind: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            switch tab {
            case .kinds:
                KindStatisticsView(session: session) { kind in
                    listKind = kind
                    tab = .files
                }
            case .files:
                SelectionListView(session: session, kind: $listKind)
            case .info:
                InfoView(session: session)
            }
        }
    }
}

// MARK: - Kinds

/// A small image of a cushion in the colour of a file kind.
private struct KindSwatch: View {
    let color: RGB

    var body: some View {
        // rendered at 2x for sharp edges on Retina displays
        let buffer = CushionRenderer.renderSwatch(width: 72, height: 28, color: color)
        if let image = buffer.cgImage {
            Image(decorative: image, scale: 2)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}

struct KindStatisticsView: View {
    let session: FolderSession
    /// called with the kind name when the user wants to see the files of a kind
    let showFiles: (String) -> Void

    @State private var sortOrder = [KeyPathComparator(\FileKindStatistic.size, order: .reverse)]
    @State private var selection: String?
    @AppStorage(Prefs.smallFontInKindStatistic) private var smallFont = false

    var body: some View {
        let stats = session.kindStatistics.sorted(using: sortOrder)
        let total = max(1, stats.reduce(UInt64(0)) { $0 + $1.size })

        Table(stats, selection: $selection, sortOrder: $sortOrder) {
            // (every column has a sort key: a Table with a sortOrder needs columns of one comparator type)
            TableColumn("Color", value: \.kindName) { stat in
                KindSwatch(color: session.colors.color(forKind: stat.kindName))
            }
            .width(40)

            TableColumn("Kind", value: \.kindName)

            TableColumn("Size", value: \.size) { stat in
                Text(SizeFormatting.string(forBytes: stat.size)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)

            TableColumn("%", value: \.size) { stat in
                Text(SizeFormatting.percentString(Double(stat.size) / Double(total))).monospacedDigit()
            }
            .width(min: 50, ideal: 60)

            TableColumn("Files", value: \.fileCount) { stat in
                Text("\(stat.fileCount)").monospacedDigit()
            }
            .width(min: 40, ideal: 55)
        }
        .font(smallFont ? .callout : .body)
        .contextMenu(forSelectionType: String.self) { kinds in
            if let kind = kinds.first {
                Button("Show Files in Selection List") { showFiles(kind) }
            }
        } primaryAction: { kinds in
            if let kind = kinds.first { showFiles(kind) }
        }
        // keep the highlighted kind in sync with the selected file
        .onChange(of: session.selectedItem, initial: true) { _, item in
            if let item, !session.isNode(item) {
                selection = item.kindName
            } else {
                selection = nil
            }
        }
    }
}

// MARK: - Selection list

struct SelectionListView: View {
    let session: FolderSession
    @Binding var kind: String?

    @State private var searchText = ""
    @State private var field: SearchField = .all
    @State private var sortOrder = [KeyPathComparator(\FSItem.size, order: .reverse)]
    @State private var rows: [FSItem] = []
    @State private var selection: FSItem.ID?
    @AppStorage(Prefs.smallFontInSelectionList) private var smallFont = false

    /// everything the list depends on except the sort order
    private struct Query: Equatable {
        var revision: Int
        var kind: String?
        var text: String
        var field: SearchField
    }

    var body: some View {
        VStack(spacing: 6) {
            Picker("Kind", selection: $kind) {
                Text("(all kinds)").tag(String?.none)
                ForEach(session.kindStatistics) { stat in
                    Text(stat.kindName).tag(String?.some(stat.kindName))
                }
            }
            .padding(.horizontal, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("Search in", selection: $field) {
                    ForEach(SearchField.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 8)

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { item in
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
                TableColumn("Size", value: \.size) { item in
                    Text(SizeFormatting.string(forBytes: item.size)).monospacedDigit()
                }
                .width(min: 60, ideal: 80)
                TableColumn("Folder", value: \.folderPath) { item in
                    Text(item.folderPath).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                }
            }
            .font(smallFont ? .callout : .body)

            Text("\(rows.count) files")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
        }
        .task(id: Query(revision: session.revision, kind: kind, text: searchText, field: field)) {
            // wait a moment while the user is still typing
            if !searchText.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            reload()
        }
        .onChange(of: sortOrder) { _, newOrder in
            rows.sort(using: newOrder)
        }
        .onChange(of: selection) { _, id in
            guard let id, session.selectedItem?.id != id, let item = rows.first(where: { $0.id == id }) else { return }
            session.select(item)
        }
        .onChange(of: session.selectedItem, initial: true) { _, item in
            selection = item?.id
        }
    }

    private func reload() {
        // the kind may not exist any more (e.g. after zooming into another folder)
        if let kind, !session.kindStatistics.contains(where: { $0.kindName == kind }) {
            self.kind = nil
            return
        }
        var items = session.items(ofKind: kind)
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            items = FSItemSearch.filter(items, text: searchText, field: field)
        }
        items.sort(using: sortOrder)
        rows = items
    }
}

// MARK: - Info

struct InfoView: View {
    let session: FolderSession

    private struct Details {
        var created: Date?
        var modified: Date?
        var owner: String?
        var group: String?
        var permissions: String?
        var opensWith: String?
    }

    @State private var details = Details()

    var body: some View {
        if let item = session.selectedItem ?? session.zoomedItem {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                            .resizable()
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading) {
                            Text(item.displayName).font(.headline).textSelection(.enabled)
                            Text(item.kindName).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    LabeledContent("Size", value: SizeFormatting.string(forBytes: item.size(for: session.sizeMode)))
                    LabeledContent("Logical size", value: SizeFormatting.string(forBytes: item.logicalSize))
                    LabeledContent("Physical size", value: SizeFormatting.string(forBytes: item.physicalSize))
                    if item.isFolder {
                        LabeledContent("Files", value: "\(item.deepFileCount(includingPackages: true))")
                    }
                }
                Section {
                    LabeledContent("Path") {
                        Text(item.path).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                    if let created = details.created {
                        LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let modified = details.modified {
                        LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let owner = details.owner { LabeledContent("Owner", value: owner) }
                    if let group = details.group { LabeledContent("Group", value: group) }
                    if let permissions = details.permissions { LabeledContent("Permissions", value: permissions) }
                    if let app = details.opensWith { LabeledContent("Opens with", value: app) }
                }
            }
            .formStyle(.grouped)
            .task(id: item.id) { details = Self.loadDetails(for: item) }
        } else {
            ContentUnavailableView("No Selection", systemImage: "info.circle")
        }
    }

    private static func loadDetails(for item: FSItem) -> Details {
        var d = Details()
        let attributes = try? FileManager.default.attributesOfItem(atPath: item.path)
        d.created = attributes?[.creationDate] as? Date
        d.modified = attributes?[.modificationDate] as? Date
        d.owner = attributes?[.ownerAccountName] as? String
        d.group = attributes?[.groupOwnerAccountName] as? String
        if let perm = attributes?[.posixPermissions] as? Int {
            d.permissions = String(perm, radix: 8)
        }
        if !item.isFolder, let app = NSWorkspace.shared.urlForApplication(toOpen: item.url) {
            d.opensWith = FileManager.default.displayName(atPath: app.path)
        }
        return d
    }
}
