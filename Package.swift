// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Transnap",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Transnap", targets: ["Transnap"]),
    ],
    targets: [
        .executableTarget(
            name: "Transnap",
            path: "Sources/Transnap",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("NaturalLanguage"),
            ]
        ),
    ]
)
