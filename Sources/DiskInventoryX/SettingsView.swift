import SwiftUI

/// The application settings (standard Settings window, ⌘,).
struct SettingsView: View {
    @AppStorage(Prefs.showPackageContents) private var showPackageContents = false
    @AppStorage(Prefs.showFreeSpace) private var showFreeSpace = false
    @AppStorage(Prefs.showOtherSpace) private var showOtherSpace = false
    @AppStorage(Prefs.showPhysicalFileSize) private var physicalSizes = false
    @AppStorage(Prefs.shareKindColors) private var shareColors = false

    @AppStorage(Prefs.splitWindowHorizontally) private var splitHorizontally = false
    @AppStorage(Prefs.smallFontInFilesView) private var smallFilesFont = false
    @AppStorage(Prefs.smallFontInKindStatistic) private var smallKindsFont = false
    @AppStorage(Prefs.smallFontInSelectionList) private var smallListFont = false

    var body: some View {
        TabView {
            Form {
                Section("New Windows Start With") {
                    Toggle("Show package contents", isOn: $showPackageContents)
                    Toggle("Show free space in the treemap", isOn: $showFreeSpace)
                    Toggle("Show other space in the treemap", isOn: $showOtherSpace)
                    Toggle("Use physical file sizes (space allocated on disk)", isOn: $physicalSizes)
                }
                Section("Colors") {
                    Toggle("Use the same colors for the same file kinds in all windows", isOn: $shareColors)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Window") {
                    Toggle("Show file tree above the treemap instead of beside it", isOn: $splitHorizontally)
                }
                Section("Small Font") {
                    Toggle("File tree", isOn: $smallFilesFont)
                    Toggle("File kind statistics", isOn: $smallKindsFont)
                    Toggle("Selection list", isOn: $smallListFont)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Appearance", systemImage: "textformat.size") }
        }
        .frame(width: 520, height: 330)
    }
}
