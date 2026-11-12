// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailStore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MailStore", targets: ["MailStore"]),
    ],
    targets: [
        .target(name: "MailStore"),
        .testTarget(name: "MailStoreTests", dependencies: ["MailStore"]),
    ]
)
