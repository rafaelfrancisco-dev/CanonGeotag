// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CanonProtocol",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "CanonProtocol", targets: ["CanonProtocol"]),
    ],
    targets: [
        .target(name: "CanonProtocol"),
        .testTarget(name: "CanonProtocolTests", dependencies: ["CanonProtocol"]),
    ],
    swiftLanguageModes: [.v6]
)
