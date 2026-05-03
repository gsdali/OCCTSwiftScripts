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
        // OCCTSwift v0.157+ pins to OCCT 8.0.0 beta1 (xcframework rebuilt against
        // V8_0_0_beta1; internal BRepGraph bridge migrations to EditorView /
        // NCollection_DynamicArray; Swift public API unchanged). Floor is
        // v0.165.0 — earlier v0.157-v0.164 had a broken Package.swift binary
        // target URL still pointing at the rc-era v0.131.0 xcframework
        // (OCCTSwift#97), so remote SPM consumers couldn't compile against
        // those tags. Soak window per OCCTSwiftScripts#36; bump to from: "1.0.0"
        // when OCCT 8.0.0 GA tags on 2026-05-07.
        .package(url: "https://github.com/gsdali/OCCTSwift.git", from: "0.165.0"),
        // OCCTSwiftViewport v0.55.0+ no longer ships OCCTSwiftTools as a
        // sub-product — that bridge layer was split into its own repo to
        // share with OCCTSwiftAIS (a sibling toolkit). We declare both as
        // direct deps below.
        .package(url: "https://github.com/gsdali/OCCTSwiftViewport.git", from: "0.55.0"),
        .package(url: "https://github.com/gsdali/OCCTSwiftTools.git", from: "0.4.1"),
        // OCCTSwiftMesh: mesh-domain algorithms (decimation today; smoothing /
        // repair / remeshing in future releases). Vendors meshoptimizer
        // (BSD-2-Clause / MIT-equivalent) inside an LGPL-2.1 wrapper. Powers
        // the `simplify-mesh` verb.
        .package(url: "https://github.com/gsdali/OCCTSwiftMesh.git", from: "0.1.0"),
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
                .product(name: "OCCTSwiftTools", package: "OCCTSwiftTools"),
                .product(name: "OCCTSwiftMesh", package: "OCCTSwiftMesh"),
            ],
            path: "Sources/occtkit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
