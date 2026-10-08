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
        // releases with the headers and module map in Headers/RaTeXFFI/,
        // so they don't collide with other xcframeworks' include/module.modulemap.
        .binaryTarget(
            name: "RaTeX",
            url: "https://github.com/coditynet/enriched-markdown-ios/releases/download/ratex-v0.1.14-1/RaTeX.xcframework.zip",
            checksum: "2c02554bcc30184b59084efffe41c1e4490fc13441b4f34af72da90c4eddff22"
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
