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
        .package(url: "https://github.com/gsdali/OCCTSwift.git", from: "0.152.0"),
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
            ],
            path: "Sources/occtkit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
