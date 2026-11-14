// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailStore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MailStore", targets: ["MailStore"]),
        .library(name: "MailStoreSwiftData", targets: ["MailStoreSwiftData"]),
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
        // SwiftData での保存。Apple の SwiftData を使うので、Linux では中身が空になる。
        .target(name: "MailStoreSwiftData", dependencies: ["MailStore"]),
        .testTarget(
            name: "MailStoreTests",
            dependencies: [
                "MailStore",
                "MailStoreSwiftData",
                .product(name: "MailCore", package: "MailCore"),
                .product(name: "AccountKit", package: "AccountKit"),
            ]
        ),
    ]
)
