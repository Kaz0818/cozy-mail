// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AccountKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AccountKit", targets: ["AccountKit"]),
        .library(name: "AccountKitKeychain", targets: ["AccountKitKeychain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        .target(
            name: "AccountKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        // キーチェーンの実装。Apple の Security フレームワークを使うので、Linux では中身が空になる。
        .target(name: "AccountKitKeychain", dependencies: ["AccountKit"]),
        .testTarget(
            name: "AccountKitTests",
            dependencies: [
                "AccountKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ]
)
