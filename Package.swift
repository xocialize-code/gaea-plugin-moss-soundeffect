// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-moss-soundeffect: OpenMOSS's MOSS-SoundEffect v2.0 (Apache-2.0 weights) as a Gaea plugin on MES Audio
// 0.1's audio.generate. One worker executable built on GaeaPluginKit over mlx-moss-soundeffect-swift, packaged as a
// signed .gaeaplugin by scripts/build-plugin.sh.
//
// moss-sfx-inproc is not part of the plugin: it runs the same package in-process through MLXServeEngine, with the same
// dependency resolution and requests, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-moss-soundeffect",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.8.0"),
        .package(url: "https://github.com/xocialize/mlx-moss-soundeffect-swift.git", exact: "0.4.0"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.73.1"),
    ],
    targets: [
        .target(
            name: "MossSFXPlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXMossSoundEffect", package: "mlx-moss-soundeffect-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-moss-soundeffect-worker",
            dependencies: [
                "MossSFXPlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "moss-sfx-inproc",
            dependencies: [
                "MossSFXPlugin",
                .product(name: "GaeaProtocol", package: "gaea-plugin-kit"),
                .product(name: "MLXMossSoundEffect", package: "mlx-moss-soundeffect-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "MossSFXPluginTests", dependencies: ["MossSFXPlugin", .product(name: "MLXMossSoundEffect", package: "mlx-moss-soundeffect-swift")]),
    ]
)
