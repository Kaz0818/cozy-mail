// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AccountKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AccountKit", targets: ["AccountKit"]),
    ],
    targets: [
        .target(name: "AccountKit"),
        .testTarget(name: "AccountKitTests", dependencies: ["AccountKit"]),
    ]
)
