// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DeskDrop",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DeskDrop", targets: ["DeskDrop"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0")
    ],
    targets: [
        .executableTarget(
            name: "DeskDrop",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ],
            path: "Sources/DeskDrop"
        )
    ]
)
