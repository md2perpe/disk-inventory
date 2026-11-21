import SwiftUI
import AppKit
import DiskInventoryCore

/// A mounted volume with its capacity.
struct VolumeInfo: Identifiable {
    let url: URL
    let name: String
    let format: String
    let capacity: UInt64?
    let available: UInt64?
    let icon: NSImage

    var id: URL { url }
    var used: UInt64? {
        guard let capacity, let available, capacity >= available else { return nil }
        return capacity - available
    }

    static func mounted() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let icon = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage) ?? NSImage()
            icon.size = NSSize(width: 32, height: 32)
            return VolumeInfo(
                url: url,
                name: values?.volumeLocalizedName ?? url.lastPathComponent,
                format: values?.volumeLocalizedFormatDescription ?? "",
                capacity: values?.volumeTotalCapacity.map { UInt64(max(0, $0)) },
                available: values?.volumeAvailableCapacity.map { UInt64(max(0, $0)) },
                icon: icon)
        }
    }
}

/// Lets the user pick a volume (or any folder) to analyse. Replaces the original "Volumes" panel.
struct VolumesView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var volumes: [VolumeInfo] = []
    @State private var selection: URL?

    var body: some View {
        VStack(spacing: 0) {
            Table(volumes, selection: $selection) {
                TableColumn("Volume") { volume in
                    HStack(spacing: 8) {
                        Image(nsImage: volume.icon)
                        VStack(alignment: .leading) {
                            Text(volume.name)
                            if !volume.format.isEmpty {
                                Text(volume.format).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .width(min: 160, ideal: 220)

                TableColumn("Usage") { volume in
                    if let used = volume.used, let capacity = volume.capacity, capacity > 0 {
                        ProgressView(value: Double(used), total: Double(capacity))
                    }
                }
                .width(min: 80, ideal: 120)

                TableColumn("Capacity") { volume in
                    Text(volume.capacity.map { SizeFormatting.string(forBytes: $0) } ?? "–").monospacedDigit()
                }
                .width(min: 70, ideal: 85)

                TableColumn("Used") { volume in
                    Text(volume.used.map { SizeFormatting.string(forBytes: $0) } ?? "–").monospacedDigit()
                }
                .width(min: 70, ideal: 85)

                TableColumn("Free") { volume in
                    Text(volume.available.map { SizeFormatting.string(forBytes: $0) } ?? "–").monospacedDigit()
                }
                .width(min: 70, ideal: 85)
            }
            .contextMenu(forSelectionType: URL.self) { _ in
                // no menu, but this overload provides the double click action below
            } primaryAction: { urls in
                if let url = urls.first { open(url) }
            }

            Divider()

            HStack {
                Button("Choose Folder…") { chooseFolder() }
                Spacer()
                Button("Open Volume") {
                    if let selection { open(selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(12)
        }
        .frame(minWidth: 620, minHeight: 280)
        .navigationTitle("Choose a Volume or Folder")
        .task { volumes = VolumeInfo.mounted() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumes = VolumeInfo.mounted()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumes = VolumeInfo.mounted()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didRenameVolumeNotification)) { _ in
            volumes = VolumeInfo.mounted()
        }
    }

    private func open(_ url: URL) {
        openWindow(value: url)
        dismiss()
    }

    private func chooseFolder() {
        if let url = FolderPicker.chooseFolder() { open(url) }
    }
}

enum FolderPicker {
    @MainActor
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder or volume to analyse"
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
