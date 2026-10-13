// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CanonGeotag",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "CanonGeotag",
            targets: ["CanonGeotag"]
        ),
    ],
    dependencies: [
        .package(path: "Packages/CanonProtocol"),
    ],
    targets: [
        .target(
            name: "CanonGeotag",
            dependencies: [
                .product(name: "CanonProtocol", package: "CanonProtocol"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
