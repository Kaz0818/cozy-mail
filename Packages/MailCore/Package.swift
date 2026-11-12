// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MailCore", targets: ["MailCore"]),
    ],
    targets: [
        .target(name: "MailCore"),
        .testTarget(name: "MailCoreTests", dependencies: ["MailCore"]),
    ]
)
