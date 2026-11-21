import SwiftUI
import AppKit
import DiskInventoryCore

/// The window showing one scanned folder: file tree and treemap in a split view, an inspector on the trailing side.
struct SessionView: View {
    let session: FolderSession

    @AppStorage(Prefs.splitWindowHorizontally) private var splitHorizontally = false
    @AppStorage(Prefs.shareKindColors) private var shareColors = false
    @AppStorage(Prefs.smallFontInFilesView) private var smallFontInFiles = false

    @State private var inspectorShown = true
    @State private var inspectorTab: InspectorTab = .kinds

    var body: some View {
        content
            .navigationTitle(session.title)
            .navigationSubtitle(session.zoomedItem?.path ?? "")
            .inspector(isPresented: $inspectorShown) {
                InspectorView(session: session, tab: $inspectorTab)
                    .inspectorColumnWidth(min: 280, ideal: 360, max: 700)
            }
            .toolbar { toolbarContent }
            .task { await session.scan() }
            .onDisappear { session.cancelScan() }
            .onChange(of: shareColors) { _, shares in session.setSharesColors(shares) }
            .focusedSceneValue(\.folderSession, session)
            .focusedSceneValue(\.inspectorShown, $inspectorShown)
            .alert("Disk Inventory X", isPresented: errorBinding) {
                Button("OK") { session.errorMessage = nil }
            } message: {
                Text(session.errorMessage ?? "")
            }
            .confirmationDialog(
                "Delete “\(session.pendingDeletion?.displayName ?? "")” immediately?",
                isPresented: deletionBinding,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { session.confirmPendingDeletion() }
                Button("Cancel", role: .cancel) { session.cancelPendingDeletion() }
            } message: {
                Text("The item could not be moved to the trash because it is not on a local volume. It would be deleted immediately and this cannot be undone.")
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let failure = session.failure {
            ContentUnavailableView {
                Label("The folder's content could not be loaded", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            }
        } else if session.rootItem == nil {
            ScanProgressView(session: session)
        } else {
            splitContent
                .overlay(alignment: .bottomTrailing) {
                    if session.isScanning {
                        RefreshHUD(session: session).padding(12)
                    }
                }
        }
    }

    private var splitContent: some View {
        let tree = FilesOutlineView(
            session: session, revision: session.revision, selection: session.selectedItem, smallFont: smallFontInFiles)
            .frame(minWidth: 200, idealWidth: 320)
        let map = TreeMapPane(session: session)
            .frame(minWidth: 200, minHeight: 150)

        return Group {
            if splitHorizontally {
                VSplitView { tree; map }
            } else {
                HSplitView { tree; map }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                if let root = session.rootItem {
                    Button(root.displayName) { session.zoomOut(to: root) }
                        .disabled(session.zoomStack.isEmpty)
                    ForEach(session.zoomStack, id: \.id) { item in
                        Button(item.displayName) { session.zoomOut(to: item) }
                            .disabled(item === session.zoomedItem)
                    }
                }
            } label: {
                Label("Zoom Level", systemImage: "list.bullet.indent")
            }
            .help("Zoom out to a higher level")
            .disabled(!session.canZoomOut)

            Button { session.zoomOut() } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .help("Zoom out")
            .disabled(!session.canZoomOut)

            Button { session.zoomIn() } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .help("Zoom into the selected folder")
            .disabled(!session.canZoomIn)
        }

        ToolbarItemGroup {
            Button {
                if let item = session.selectedItem { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Show the selected item in the Finder")
            .disabled(session.selectedItem == nil)

            Button {
                if let item = session.selectedItem { Task { await session.refresh(item) } }
            } label: {
                Label("Refresh Selection", systemImage: "arrow.clockwise")
            }
            .help("Rescan the selected item")
            .disabled(session.selectedItem == nil || session.isScanning)

            Button { Task { await session.refresh(nil) } } label: {
                Label("Refresh All", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Rescan the shown folder")
            .disabled(session.isScanning)

            Button {
                if let item = session.selectedItem { session.requestTrash(item) }
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .help("Move the selected item to the Trash")
            .disabled(!session.canTrash(session.selectedItem))
        }

        ToolbarItemGroup {
            Toggle(isOn: Binding(get: { session.showPackageContents },
                                 set: { session.setShowPackageContents($0) })) {
                Label("Show Package Contents", systemImage: "shippingbox")
            }
            .toggleStyle(.button)
            .help("Show the contents of packages such as applications")

            Button { inspectorShown.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the file kinds, file list and information")
        }
    }

    // MARK: Alerts

    private var errorBinding: Binding<Bool> {
        Binding(get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } })
    }

    private var deletionBinding: Binding<Bool> {
        // dismissed through the buttons, which update the session themselves
        Binding(get: { session.pendingDeletion != nil }, set: { _ in })
    }
}

// MARK: - Pieces

private struct TreeMapPane: View {
    let session: FolderSession

    var body: some View {
        VStack(spacing: 0) {
            TreeMapView(session: session, revision: session.revision, selection: session.selectedItem)
            Divider()
            Text(statusText)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
    }

    /// Describes the item under the pointer, or the selection, or the shown folder.
    private var statusText: String {
        guard let item = session.hoveredItem ?? session.selectedItem else {
            guard let zoomed = session.zoomedItem else { return "" }
            return "\(zoomed.displayName), \(SizeFormatting.string(forBytes: zoomed.size))"
        }
        let size = SizeFormatting.string(forBytes: item.size)
        if item.isSpecialItem {
            return "\(item.displayName), \(size)"
        }
        let folder = item.parent.map { " (\($0.pathRelativeToRoot))" } ?? ""
        return "\(item.name)\(folder) — \(item.kindName), \(size)"
    }
}

private struct ScanProgressView: View {
    let session: FolderSession

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reading folder…").font(.headline)
            if let progress = session.scanProgress {
                Text(progress.currentFolder)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
                Text("\(progress.itemCount) items")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("Cancel") { session.cancelScan() }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown over the content while a refresh is running.
private struct RefreshHUD: View {
    let session: FolderSession

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(session.scanProgress?.currentFolder ?? "Refreshing…")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .leading)
            Button("Cancel") { session.cancelScan() }
                .controlSize(.small)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
