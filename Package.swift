// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ByteMsg233",
    products: [
        .library(name: "ByteMsg233", targets: ["ByteMsg233"]),
    ],
    targets: [
        .target(name: "ByteMsg233", path: "Sources/ByteMsg233"),
    ]
)
