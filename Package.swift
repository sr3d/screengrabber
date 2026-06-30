// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "screengrabber",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Auto-update framework. The XCFramework also bundles the signing tools
        // (generate_keys / sign_update / generate_appcast) used by release CI.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "screengrabber",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/screengrabber",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("ServiceManagement"),
                // `swift build` doesn't assemble an .app bundle, so point the
                // runtime loader at the Sparkle.framework that build.sh copies
                // into Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath",
                              "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
