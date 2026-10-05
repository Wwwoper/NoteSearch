// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoteSearchCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "NoteSearchCore",
            path: "NoteSearch",
            exclude: [
                "NoteSearchApp.swift",
                "Info.plist",
                "Assets.xcassets",
                "Preview Content",
                "Views",
                "Models/AppState.swift",
                "Services/GlobalHotkeyHandler.swift"
            ],
            sources: [
                "Models/SearchModels.swift",
                "Services/AppLog.swift",
                "Services/SearchService.swift",
                "Services/IndexService.swift"
            ]
        ),
        .testTarget(
            name: "NoteSearchCoreTests",
            dependencies: ["NoteSearchCore"],
            path: "Tests/NoteSearchCoreTests"
        )
    ]
)
