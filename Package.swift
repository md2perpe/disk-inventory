// swift-tools-version:5.9
import PackageDescription

// Layers:
//   TreeMapKit         - pure Swift: treemap layout, cushion shading, hit testing (no UI, no Foundation file APIs)
//   DiskInventoryCore  - Foundation only: file tree model, folder scanner, kind statistics, colors
//   DiskInventoryX     - the macOS SwiftUI application (only built on macOS)
//   treemap-demo       - command line tool that renders a folder to a PNG (handy for testing on any platform)

var targets: [Target] = [
    .target(name: "TreeMapKit"),
    .target(name: "DiskInventoryCore", dependencies: ["TreeMapKit"]),
    .executableTarget(name: "treemap-demo", dependencies: ["TreeMapKit", "DiskInventoryCore"]),
    .testTarget(name: "TreeMapKitTests", dependencies: ["TreeMapKit"]),
    .testTarget(name: "DiskInventoryCoreTests", dependencies: ["DiskInventoryCore", "TreeMapKit"]),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "DiskInventoryX",
        dependencies: ["TreeMapKit", "DiskInventoryCore"]
    )
)
#endif

let package = Package(
    name: "DiskInventoryX",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TreeMapKit", targets: ["TreeMapKit"]),
        .library(name: "DiskInventoryCore", targets: ["DiskInventoryCore"]),
    ],
    targets: targets
)
