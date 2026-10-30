// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VidFlowCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.library(name: "VidFlowCore", targets: ["VidFlowCore"])],
    targets: [
        .target(name: "VidFlowCore", resources: [.copy("Resources/Strings.tsv"), .copy("Resources/Strings.mac.tsv")]),
        .testTarget(name: "VidFlowCoreTests", dependencies: ["VidFlowCore"]),
    ]
)
