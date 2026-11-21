import SwiftUI
import AppKit
import DiskInventoryCore

@main
struct DiskInventoryXApp: App {
    var body: some Scene {
        // One window per analysed folder. A window without a URL shows the volume picker.
        WindowGroup("Disk Inventory X", id: "folder", for: URL.self) { $url in
            FolderWindow(url: url)
        }
        .commands { AppCommands() }

        Window("Volumes", id: "volumes") {
            VolumesView()
        }

        Settings {
            SettingsView()
        }
    }
}

struct FolderWindow: View {
    let url: URL?

    var body: some View {
        if let url {
            SessionHost(url: url)
        } else {
            VolumesView()
        }
    }
}

/// Owns the session of a window.
@MainActor
private struct SessionHost: View {
    @State private var session: FolderSession

    init(url: URL) {
        // (the initial value is only used once; later inits of this struct keep the existing state)
        _session = State(initialValue: FolderSession(url: url, options: .fromDefaults()))
    }

    var body: some View {
        SessionView(session: session)
    }
}

// MARK: - Menu commands

private struct FolderSessionKey: FocusedValueKey { typealias Value = FolderSession }
private struct InspectorShownKey: FocusedValueKey { typealias Value = Binding<Bool> }

extension FocusedValues {
    var folderSession: FolderSession? {
        get { self[FolderSessionKey.self] }
        set { self[FolderSessionKey.self] = newValue }
    }
    var inspectorShown: Binding<Bool>? {
        get { self[InspectorShownKey.self] }
        set { self[InspectorShownKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.folderSession) private var session
    @FocusedValue(\.inspectorShown) private var inspectorShown
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") {
                if let url = FolderPicker.chooseFolder() { openWindow(value: url) }
            }
            .keyboardShortcut("o")

            Button("Open Volume…") { openWindow(id: "volumes") }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Show in Finder") {
                if let item = session?.selectedItem { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(session?.selectedItem == nil)

            Button("Refresh Selection") {
                if let session, let item = session.selectedItem { Task { await session.refresh(item) } }
            }
            .keyboardShortcut("r")
            .disabled(session?.selectedItem == nil || session?.isScanning == true)

            Button("Refresh All") {
                if let session { Task { await session.refresh(nil) } }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(session == nil || session?.isScanning == true)

            Button("Move to Trash") {
                if let session, let item = session.selectedItem { session.requestTrash(item) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!(session?.canTrash(session?.selectedItem) ?? false))
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Button("Zoom In") { session?.zoomIn() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!(session?.canZoomIn ?? false))
            Button("Zoom Out") { session?.zoomOut() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!(session?.canZoomOut ?? false))
            Button("Select Parent") { session?.selectParent() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!(session?.canSelectParent ?? false))

            Divider()
            Toggle("Show Package Contents", isOn: Binding(
                get: { session?.showPackageContents ?? false },
                set: { session?.setShowPackageContents($0) }))
                .disabled(session == nil)
            Toggle("Show Free Space", isOn: Binding(
                get: { session?.showFreeSpace ?? false },
                set: { session?.setShowFreeSpace($0) }))
                .disabled(session == nil)
            Toggle("Show Other Space", isOn: Binding(
                get: { session?.showOtherSpace ?? false },
                set: { session?.setShowOtherSpace($0) }))
                .disabled(!(session?.canShowOtherSpace ?? false))
            Toggle("Show Physical File Size", isOn: Binding(
                get: { session?.sizeMode == .physical },
                set: { session?.setPhysicalSizes($0) }))
                .disabled(session == nil)

            Divider()
            Button("Toggle Inspector") { inspectorShown?.wrappedValue.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(inspectorShown == nil)
        }
    }
}
