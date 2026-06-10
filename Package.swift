// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "screengrabber",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "screengrabber",
            path: "Sources/screengrabber",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
