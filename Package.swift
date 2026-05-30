// swift-tools-version: 6.2
import PackageDescription

// swift-parsing: a performant, multi-backend parsing framework for Swift.
//
// The core (`ParsingCore`) is pure Swift with zero dependencies. Heavier backends (the C-backed
// tree-sitter wrapper, future ANTLR wrappers) live in their own packages so this one never inherits C
// or the JVM, keeping the embedded, musl and WebAssembly builds clean. The tree-sitter backend and the
// differential test harness live in the companion `swift-parsing-tree-sitter` package.

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

// ParsingCore is the embedded-safe heart of the framework. The EmbeddedRestrictions diagnostic flags
// constructs that Embedded Swift cannot compile (existentials, untyped throws, Foundation, ...) during a
// normal host build, so incompatibilities are caught here long before the dedicated embedded compile gate.
let embeddedSafe: [SwiftSetting] = strict + [
    .enableExperimentalFeature("EmbeddedRestrictions")
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
        .library(name: "Parsing", targets: ["Parsing"]),
        .library(name: "ParsingDSL", targets: ["ParsingDSL"]),
        .library(name: "RecursiveDescent", targets: ["RecursiveDescent"]),
        .library(name: "GrammarImport", targets: ["GrammarImport"]),
        .library(name: "Query", targets: ["Query"]),
        .library(name: "G4Import", targets: ["G4Import"]),
        .library(name: "EBNFImport", targets: ["EBNFImport"]),
        .executable(name: "swift-parsing", targets: ["swift-parsing"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "ParsingCore", swiftSettings: embeddedSafe),
        .target(name: "Parsing", dependencies: ["ParsingCore"], swiftSettings: strict),
        .target(name: "ParsingDSL", dependencies: ["ParsingCore"], swiftSettings: strict),
        .target(name: "RecursiveDescent", dependencies: ["ParsingCore"], swiftSettings: strict),
        .target(name: "GrammarImport", dependencies: ["ParsingCore", "Parsing"], swiftSettings: strict),
        .target(name: "Query", dependencies: ["ParsingCore"], swiftSettings: strict),
        .target(name: "G4Import", dependencies: ["ParsingCore", "Parsing"], swiftSettings: strict),
        .target(name: "EBNFImport", dependencies: ["ParsingCore"], swiftSettings: strict),
        .executableTarget(
            name: "swift-parsing",
            dependencies: [
                "ParsingCore", "ParsingDSL", "RecursiveDescent", "GrammarImport",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strict
        ),

        .testTarget(name: "ParsingCoreTests", dependencies: ["ParsingCore"], swiftSettings: strict),
        .testTarget(name: "ParsingTests", dependencies: ["Parsing", "ParsingCore"], swiftSettings: strict),
        .testTarget(name: "ParsingDSLTests", dependencies: ["ParsingDSL", "ParsingCore"], swiftSettings: strict),
        .testTarget(name: "RecursiveDescentTests", dependencies: ["RecursiveDescent", "ParsingDSL", "ParsingCore"], swiftSettings: strict),
        .testTarget(name: "GrammarImportTests", dependencies: ["GrammarImport", "ParsingDSL", "ParsingCore", "RecursiveDescent"], swiftSettings: strict),
        .testTarget(name: "QueryTests", dependencies: ["Query", "ParsingDSL", "ParsingCore", "RecursiveDescent"], swiftSettings: strict),
        .testTarget(name: "G4ImportTests", dependencies: ["G4Import", "ParsingDSL", "ParsingCore", "RecursiveDescent"], swiftSettings: strict),
        .testTarget(name: "EBNFImportTests", dependencies: ["EBNFImport", "ParsingDSL", "ParsingCore", "RecursiveDescent"], swiftSettings: strict),
    ]
)

// The swift-parsing executable cannot be `@testable import`ed when cross-compiling (the executable
// module is not emitted for a non-host triple), so its test target is omitted when
// EXCLUDE_EXECUTABLE_TESTS is set. The WebAssembly test job sets it to run the library suite under
// WasmKit; every host build still tests the CLI.
if Context.environment["EXCLUDE_EXECUTABLE_TESTS"] == nil {
    package.targets.append(
        .testTarget(name: "swift-parsingTests", dependencies: ["swift-parsing"], swiftSettings: strict)
    )
}

// Documentation plugins (mipalgu/swift-docc-static and swiftlang/swift-docc-plugin) contribute only
// build-time commands (`generate-static-documentation`, `generate-documentation`), never product code,
// but they pull in a large dependency graph (SwiftNIO, swift-crypto, cmark, ...). They are added only
// when the DOCUMENTATION environment variable is set (as the docs CI job does), so normal and
// cross-platform builds neither resolve nor compile that graph.
if Context.environment["DOCUMENTATION"] != nil {
    package.dependencies.append(contentsOf: [
        .package(url: "https://github.com/mipalgu/swift-docc-static.git", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.1.0"),
    ])
}

// Performance benchmarks (ordo-one/package-benchmark) are opt-in: they depend on jemalloc and do not
// build on WebAssembly or static musl, so the target and its dependency are added only when the
// BENCHMARK environment variable is set (as the dedicated `swift package benchmark` CI job does). Every
// other build, including the cross-platform matrix, never resolves or compiles them.
if Context.environment["BENCHMARK"] != nil {
    package.dependencies.append(
        .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.29.0")
    )
    package.targets.append(
        .executableTarget(
            name: "ParseBenchmarks",
            dependencies: [
                "ParsingCore", "ParsingDSL", "RecursiveDescent",
                .product(name: "Benchmark", package: "package-benchmark"),
            ],
            path: "Benchmarks/ParseBenchmarks",
            swiftSettings: strict,
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        )
    )
}
