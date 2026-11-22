import Foundation
import DiskInventoryCore

/// UserDefaults keys (the same names the original Objective-C application used).
enum Prefs {
    static let showPackageContents = "ShowPackageContents"
    static let showFreeSpace = "ShowFreeSpace"
    static let showOtherSpace = "ShowOtherSpace"
    static let showPhysicalFileSize = "ShowPhysicalFileSize"
    static let smallFontInFilesView = "UseSmallFontInFilesView"
    static let smallFontInKindStatistic = "UseSmallFontInKindStatisticView"
    static let smallFontInSelectionList = "UseSmallFontInSelectionList"
    static let splitWindowHorizontally = "SplitWindowHorizontally"
    static let shareKindColors = "ShareKindColors"

    /// Values used until the user changes a setting. Sizes default to the space actually allocated on disk,
    /// which is what matters when looking for what fills a disk (sparse files, e.g. virtual machine images,
    /// can claim hundreds of gigabytes but occupy almost nothing).
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [showPhysicalFileSize: true])
    }
}

extension FolderSession.Options {
    /// The options a new window starts with (taken from the settings).
    @MainActor
    static func fromDefaults() -> FolderSession.Options {
        let d = UserDefaults.standard
        var o = FolderSession.Options()
        o.showPackageContents = d.bool(forKey: Prefs.showPackageContents)
        o.showFreeSpace = d.bool(forKey: Prefs.showFreeSpace)
        o.showOtherSpace = d.bool(forKey: Prefs.showOtherSpace)
        o.physicalSizes = d.bool(forKey: Prefs.showPhysicalFileSize)
        o.sharesColors = d.bool(forKey: Prefs.shareKindColors)
        return o
    }
}
