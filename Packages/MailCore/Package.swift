// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MailCore", targets: ["MailCore"]),
        .executable(name: "cozymail-probe", targets: ["cozymail-probe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-imap.git", from: "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        // 確認用ツールの Gmail ログインだけで使う (MailCore 本体は AccountKit に依存しない)
        .package(path: "../AccountKit"),
    ],
    targets: [
        .target(
            name: "MailCore",
            dependencies: [
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .executableTarget(
            name: "cozymail-probe",
            dependencies: ["MailCore", .product(name: "AccountKit", package: "AccountKit")]
        ),
        .testTarget(
            name: "MailCoreTests",
            dependencies: [
                "MailCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
