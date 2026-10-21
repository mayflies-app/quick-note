// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickNote",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuickNoteCore", targets: ["QuickNoteCore"]),
        .executable(name: "QuickNote", targets: ["QuickNote"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "QuickNoteCore", dependencies: ["CSQLite"], resources: [.process("Resources")]),
        .executableTarget(name: "QuickNote", dependencies: ["QuickNoteCore"]),
        .testTarget(name: "QuickNoteCoreTests", dependencies: ["QuickNoteCore", "CSQLite"]),
        .testTarget(name: "QuickNoteTests", dependencies: ["QuickNote", "QuickNoteCore"])
    ],
    swiftLanguageModes: [.v5]
)
