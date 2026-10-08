// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EnrichedMarkdown",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "EnrichedMarkdown", targets: ["EnrichedMarkdown"]),
        // Optional LaTeX math rendering — links the prebuilt RaTeX engine
        // (~3-5 MB of app size); without it, `$…$` stays plain text.
        .library(name: "EnrichedMarkdownLaTeX", targets: ["EnrichedMarkdownLaTeX"])
    ],
    targets: [
        .target(
            name: "EnrichedMarkdownCore",
            path: "core",
            sources: ["md4c", "parser"],
            publicHeadersPath: "parser",
            cSettings: [
                .define("MD4C_USE_UTF8", to: "1")
            ],
            cxxSettings: [
                .headerSearchPath("md4c"),
                .headerSearchPath("parser")
            ]
        ),
        .target(
            name: "EnrichedMarkdownCppShim",
            dependencies: ["EnrichedMarkdownCore"],
            path: "cpp",
            publicHeadersPath: ".",
            cxxSettings: [
                .headerSearchPath("../core/md4c"),
                .headerSearchPath("../core/parser"),
                .define("MD4C_USE_UTF8", to: "1")
            ]
        ),
        .target(
            name: "EnrichedMarkdown",
            dependencies: ["EnrichedMarkdownCppShim"],
            path: "Sources/EnrichedMarkdown"
        ),
        // Prebuilt RaTeX layout engine (Rust behind a C FFI; imports as
        // RaTeXFFI): erweixin/RaTeX v0.1.14, re-hosted on this fork's
        // releases with the same sha256 as the monorepo's
        // vendor/ratex-version.json.
        .binaryTarget(
            name: "RaTeX",
            url: "https://github.com/coditynet/enriched-markdown-ios/releases/download/ratex-v0.1.14/RaTeX.xcframework.zip",
            checksum: "16b84a5e9b9f80ed4910c490f96dda047662e9bdd0934817ecf4464cf02581f2"
        ),
        // Vendor/'s upstream RaTeX sources (see Vendor/LICENSE) and the KaTeX
        // Fonts are symlinks into the RN package's vendored files —
        // materialized by `yarn install`, pinned in vendor/ratex-version.json,
        // and dereferenced into real files when the standalone repo is synced.
        .target(
            name: "EnrichedMarkdownLaTeX",
            dependencies: ["EnrichedMarkdown", "RaTeX"],
            path: "Sources/EnrichedMarkdownLaTeX",
            exclude: ["Vendor/LICENSE"],
            resources: [.copy("Fonts")]
        ),
        .testTarget(
            name: "EnrichedMarkdownTests",
            dependencies: ["EnrichedMarkdown"],
            path: "Tests/EnrichedMarkdownTests"
        ),
        .testTarget(
            name: "EnrichedMarkdownLaTeXTests",
            dependencies: ["EnrichedMarkdownLaTeX"],
            path: "Tests/EnrichedMarkdownLaTeXTests"
        )
    ]
)
