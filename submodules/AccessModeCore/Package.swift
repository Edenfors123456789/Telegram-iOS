// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AccessModeCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "AccessModeCore", targets: ["AccessModeCore"])],
    targets: [
        .target(name: "AccessModeCore", path: "Sources"),
        .testTarget(name: "AccessModeCoreTests", dependencies: ["AccessModeCore"], path: "Tests")
    ]
)
