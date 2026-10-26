// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RoundtableCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RoundtableCore", targets: ["RoundtableCore"]),
    ],
    targets: [
        .target(name: "RoundtableCore"),
        .testTarget(name: "RoundtableCoreTests", dependencies: ["RoundtableCore"]),
    ]
)
