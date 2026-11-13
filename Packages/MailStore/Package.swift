// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailStore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MailStore", targets: ["MailStore"]),
    ],
    dependencies: [
        .package(path: "../MailCore"),
        .package(path: "../AccountKit"),
    ],
    targets: [
        .target(
            name: "MailStore",
            dependencies: [
                .product(name: "MailCore", package: "MailCore"),
                .product(name: "AccountKit", package: "AccountKit"),
            ]
        ),
        .testTarget(
            name: "MailStoreTests",
            dependencies: [
                "MailStore",
                .product(name: "MailCore", package: "MailCore"),
                .product(name: "AccountKit", package: "AccountKit"),
            ]
        ),
    ]
)
