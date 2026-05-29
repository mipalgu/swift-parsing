// swift-tools-version: 6.2
import PackageDescription

// swift-parsing: a performant, multi-backend parsing framework for Swift.
//
// The core (`ParsingCore`) is pure Swift with zero dependencies. Heavier backends
// (the C-backed tree-sitter wrapper, future ANTLR wrappers) live in separate
// products so the core never inherits C or the JVM, keeping musl/WASM builds clean.

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

let package = Package(
    name: "SwiftParsing",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "ParsingCore", targets: ["ParsingCore"]),
        .library(name: "ParsingDSL", targets: ["ParsingDSL"]),
        .library(name: "RecursiveDescent", targets: ["RecursiveDescent"]),
        .library(name: "GrammarImport", targets: ["GrammarImport"]),
    ],
    targets: [
        .target(name: "ParsingCore", swiftSettings: strict),
        .target(name: "ParsingDSL", dependencies: ["ParsingCore"], swiftSettings: strict),
        .target(name: "RecursiveDescent", dependencies: ["ParsingCore"], swiftSettings: strict),
        .target(name: "GrammarImport", dependencies: ["ParsingCore"], swiftSettings: strict),

        .testTarget(name: "ParsingCoreTests", dependencies: ["ParsingCore"], swiftSettings: strict),
        .testTarget(name: "ParsingDSLTests", dependencies: ["ParsingDSL", "ParsingCore"], swiftSettings: strict),
        .testTarget(name: "RecursiveDescentTests", dependencies: ["RecursiveDescent", "ParsingDSL", "ParsingCore"], swiftSettings: strict),
        .testTarget(name: "GrammarImportTests", dependencies: ["GrammarImport", "ParsingDSL", "ParsingCore"], swiftSettings: strict),
    ]
)
