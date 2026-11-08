// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aegis",
    platforms: [.macOS("15.4")],
    products: [
        .executable(name: "Aegis", targets: ["AegisApp"]),
    ],
    targets: [
        .executableTarget(
            name: "AegisApp",
            dependencies: ["BrowserCore", "WebEngine", "ContentBlocking", "Persistence", "Search", "Credentials", "ChromeUI"]
        ),
        .target(name: "BrowserCore"),
        .target(
            name: "WebEngine",
            dependencies: ["BrowserCore", "ContentBlocking"],
            resources: [.copy("Resources/js")]
        ),
        .target(
            name: "ContentBlocking",
            resources: [.copy("Resources/lists")]
        ),
        .target(name: "Persistence", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "Search", dependencies: ["Persistence", "BrowserCore"]),
        .target(name: "Credentials"),
        .target(name: "ChromeUI", dependencies: ["BrowserCore", "Search"]),

        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
        .testTarget(name: "SearchTests", dependencies: ["Search", "Persistence"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
        .testTarget(name: "ContentBlockingTests", dependencies: ["ContentBlocking"]),
    ]
)
