// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Koedex",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "Koedex",
            path: "Sources/Koedex",
            resources: [
                .copy("Resources/prompts"),
                .copy("Resources/ja.lproj"),
                .copy("Resources/en.lproj")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
