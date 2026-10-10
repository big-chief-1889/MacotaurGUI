// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacotaurGUI",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Developed side by side with the miner; switch to the GitHub URL and
        // a version once Macotaur is tagged.
        .package(path: "../Macotaur"),
    ],
    targets: [
        // Power and clock telemetry. IOReport is loaded with dlopen (never
        // linked), so a Mac without it only loses those readings.
        .target(
            name: "CMacotaurPower",
            linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "MacotaurApp",
            dependencies: ["CMacotaurPower", .product(name: "MacotaurCore", package: "Macotaur")]
        ),
        .testTarget(
            name: "MacotaurAppTests",
            dependencies: ["MacotaurApp", .product(name: "MacotaurCore", package: "Macotaur")]
        ),
    ]
)
