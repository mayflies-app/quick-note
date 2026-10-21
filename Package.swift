// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickNote",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuickNoteCore", targets: ["QuickNoteCore"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "QuickNoteCore", dependencies: ["CSQLite"], resources: [.process("Resources")]),
        .testTarget(name: "QuickNoteCoreTests", dependencies: ["QuickNoteCore", "CSQLite"]),
    ],
    swiftLanguageModes: [.v5]
)
