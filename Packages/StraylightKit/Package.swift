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
        // Development tool for checking the probers against `ping`; not shipped.
        .executableTarget(name: "straylight-probe", dependencies: ["StraylightKit"]),
        .testTarget(name: "StraylightKitTests", dependencies: ["StraylightKit"]),
    ]
)
