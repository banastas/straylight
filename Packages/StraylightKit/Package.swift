// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StraylightKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "StraylightKit", targets: ["StraylightKit"]),
    ],
    targets: [
        .target(name: "StraylightKit"),
        .testTarget(name: "StraylightKitTests", dependencies: ["StraylightKit"]),
    ]
)
