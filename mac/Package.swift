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
    targets: [
        .executableTarget(
            name: "DeskDrop",
            path: "Sources/DeskDrop"
        )
    ]
)
