# Disk Inventory X (Swift)

A rewrite of [Disk Inventory X](https://gitlab.com/tderlien/disk-inventory-x) and its
[TreeMapView framework](https://gitlab.com/tderlien/treemapview-framework) in Swift, using standard system
controls wherever possible. It shows what is using your disk space as a cushion treemap, together with a
file tree, file kind statistics and a searchable file list.

Derived from the original work by Tjark Derlien and licensed under the same terms (GPL v3 or later, see `LICENSE`).

## Requirements

* a Mac with Apple Silicon (the app is built for arm64 only; Intel Macs can keep using the original app) and macOS 14 or later; built in CI with Xcode 16 (Swift 6.1). The package declares Swift tools 5.9, but older Xcode versions have not been tried
* the platform independent parts (`TreeMapKit`, `DiskInventoryCore`, tests, command line tool) also build on Linux

## Build and run

```bash
open Package.swift          # run the "DiskInventoryX" scheme in Xcode
```
```bash
Scripts/make-app.sh         # or build "build/Disk Inventory X.app" from the command line
Scripts/make-dmg.sh         # ... and pack it into "build/Disk-Inventory-X.dmg"
```
```bash
swift test                  # 76 tests (layout, rendering, model, scanner, session logic)
```
```bash
swift run -c release treemap-demo /some/folder 1600 1000 out.png   # render a folder to a PNG, no GUI needed
```

To see every folder (Library, other users, ...) give the app *Full Disk Access* in
System Settings › Privacy & Security. It only reads file sizes and types, never file contents.

## Releases

Pushing a tag starting with `v` publishes a GitHub Release with the disk image (`.github/workflows/release.yml`):

```bash
git tag v2.0 && git push origin v2.0
```

The app is not signed or notarized, so on first launch right-click it and choose *Open*.

## Structure

| Target | Contents | Replaces (original) |
|---|---|---|
| `TreeMapKit` | row-based treemap layout, cushion shading (`CushionRenderer`), hit testing. No UI, no file system. | `TreeMapView.framework`: `TMVItem`, `TMVCushionRenderer` |
| `DiskInventoryCore` | `FSItem` tree, `FolderScanner`, kind statistics, kind colors, search, and `FolderSession`, the observable "document" (zoom, selection, options, refresh, trash). | `FSItem`, `FileSystemDoc`, `FileTypeColors`, `FSItemIndex`, `NSURL-Extensions` |
| `DiskInventoryX` | the macOS app (SwiftUI) | all controllers, nibs, toolbar plist, preferences panels |
| `treemap-demo` | command line renderer | – |

### Standard widgets

| Feature | Original | Now |
|---|---|---|
| window layout | `NSSplitView` in a nib | `HSplitView` / `VSplitView` |
| file kinds + selection list | two `NSDrawer`s (deprecated) | one trailing `.inspector` with a segmented `Picker` |
| kind table, file list | `NSTableView` + `NSArrayController` + custom cells | SwiftUI `Table` with sortable columns |
| info panel | custom `NSPanel` / `DIXFileInfoView` | "Info" tab: `Form`, `LabeledContent` |
| toolbar | `OAToolbarWindowController` (OmniAppKit) | `.toolbar` |
| preferences | `PrefsPanelController` | `Settings` scene, `Form`, `@AppStorage` (same defaults keys) |
| volume picker | `DrivesPanelController` | `Table` + `ProgressView` in a `Window` scene |
| size formatting | `FileSizeFormatter` (hand written) | `ByteCountFormatter` |
| progress / alerts | `LoadingPanelController`, `NSBeginAlertSheet` | `ProgressView`, `.alert`, `.confirmationDialog` |
| menus / shortcuts | `MainMenu.nib` | `Commands`, `FocusedValue` |
| document model | `NSDocument` | one window per folder (`WindowGroup(for: URL.self)`) |
| OmniFoundation / CocoaTech dependencies | needed | none |

Two things are wrapped from AppKit because SwiftUI has no equivalent:

* the treemap itself (`TreeMapView`): a custom drawn bitmap with hit testing, hovering and a context menu
* the file tree (`FilesOutlineView`): a standard `NSOutlineView`; SwiftUI's hierarchical `Table` cannot expand rows
  programmatically, which is needed to reveal the item you clicked in the treemap

## What changed in behaviour

* Sizes default to the space *allocated on disk* (physical size), not the nominal file size. The two differ a lot for
  sparse files such as virtual machine images. It can be switched in the View menu or in Settings. (The original app
  was meant to default to the nominal size, but a bug made it always show the allocated size after loading.)
* The layout and cushion shading are a faithful port (same row algorithm, same illumination model and colors),
  with a few robustness fixes: unsorted children, zero-sized children and inconsistent parent sizes no longer trip assertions.
* Cushions are rendered in parallel and in device pixels (sharp on Retina displays).
* Scanning runs on a background thread with a progress display and a Cancel button; the UI stays responsive.
* A failed size lookup is no longer ignored (the original dropped its fallback value), so `totalFileSize`/`fileSize` and
  the allocated-size equivalents are really used as fallbacks of each other.
* Refresh keeps zoom level and selection (matched by path); when the zoomed folder is gone you are zoomed out.

## Not ported

* the animated zoom (zoom changes are immediate), the Finder plugin (already removed in the original 1.2)
* "ignore creator code" (a no-op in the original since 1.2), the donation panel, the HTML help book
* the Services menu and drag & drop *between* windows; dragging a file out of the file tree to other apps works
* localization (German, French, Spanish): all texts are English literals, so they can be localized later with a string catalog
* the privacy-protected-folders warning (macOS now asks by itself on first access)

## Status of verification

CI (`.github/workflows/macos.yml`, macOS 15, Swift 6.1) builds everything including the app, runs all 76 tests
and assembles the app bundle; this passes with no compiler warnings. The same tests also pass on Linux (Swift 6.0.3).
On Linux, a folder with 91,589 files (4.9 GB) is scanned in 0.7 s, laid out in 44 ms and rendered at 1600×1000 in 33 ms.

**Not verified: running the app.** Nobody has launched it yet, so the UI behaviour is untested: layout of the windows,
hover/selection in the treemap, revealing items in the file tree, context menus, trash, the volume picker and the
menu commands. The tests cover the model, scanner, layout and rendering, not the SwiftUI/AppKit views.
