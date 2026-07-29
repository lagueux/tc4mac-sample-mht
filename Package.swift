// swift-tools-version: 6.2
import PackageDescription

// A tc4mac packer plugin. The only dependency is the SDK — the contract the
// host and this executable both compile against.
let package = Package(
    name: "MhtPlugin",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/lagueux/tc4mac-plugin-sdk.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "MhtPlugin",
            dependencies: [.product(name: "TCPluginSDK", package: "tc4mac-plugin-sdk")]),
        .testTarget(name: "MhtPluginTests", dependencies: ["MhtPlugin"])
    ]
)
