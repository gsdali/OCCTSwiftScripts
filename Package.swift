// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OCCTSwiftScripts",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "ScriptHarness",
            targets: ["ScriptHarness"]
        ),
        .library(
            name: "DrawingComposer",
            targets: ["DrawingComposer"]
        ),
        .executable(
            name: "occtkit",
            targets: ["occtkit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/gsdali/OCCTSwift.git", from: "0.156.1"),
        // OCCTSwiftViewport: revision-pinned because the OffscreenRenderer
        // (closing OCCTSwiftViewport#18) hasn't been cut as a release yet.
        // Bump to `from: "<tag>"` when a release containing OffscreenRenderer
        // ships (latest tag at time of writing was v0.49.0 from 2026-03-16,
        // pre-OffscreenRenderer).
        .package(
            url: "https://github.com/gsdali/OCCTSwiftViewport.git",
            revision: "42ecce7c9671dab67cb3a47767a6ce98408ff7ff"
        ),
    ],
    targets: [
        .target(
            name: "ScriptHarness",
            dependencies: [
                .product(name: "OCCTSwift", package: "OCCTSwift"),
            ],
            path: "Sources/ScriptHarness",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "Script",
            dependencies: [
                "ScriptHarness",
                .product(name: "OCCTSwift", package: "OCCTSwift"),
            ],
            path: "Sources/Script",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "OCCTRunner",
            path: "Sources/OCCTRunner",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "GraphValidate",
            dependencies: [
                "ScriptHarness",
                .product(name: "OCCTSwift", package: "OCCTSwift"),
            ],
            path: "Sources/GraphValidate",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "GraphCompact",
            dependencies: [
                "ScriptHarness",
                .product(name: "OCCTSwift", package: "OCCTSwift"),
            ],
            path: "Sources/GraphCompact",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "GraphDedup",
            dependencies: [
                "ScriptHarness",
                .product(name: "OCCTSwift", package: "OCCTSwift"),
            ],
            path: "Sources/GraphDedup",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "GraphQuery",
            dependencies: [
                "ScriptHarness",
            ],
            path: "Sources/GraphQuery",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "GraphML",
            dependencies: [
                "ScriptHarness",
                .product(name: "OCCTSwift", package: "OCCTSwift"),
            ],
            path: "Sources/GraphML",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "FeatureRecognize",
            dependencies: [
                "ScriptHarness",
                .product(name: "OCCTSwift", package: "OCCTSwift"),
            ],
            path: "Sources/FeatureRecognize",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DrawingComposer",
            dependencies: [
                .product(name: "OCCTSwift", package: "OCCTSwift"),
            ],
            path: "Sources/DrawingComposer",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "occtkit",
            dependencies: [
                "ScriptHarness",
                "DrawingComposer",
                .product(name: "OCCTSwift", package: "OCCTSwift"),
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
                .product(name: "OCCTSwiftTools", package: "OCCTSwiftViewport"),
            ],
            path: "Sources/occtkit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
