// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CoachCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "CoachCore", targets: ["CoachCore"])],
    targets: [
        .target(name: "CoachCore", path: "Core"),
        .testTarget(name: "CoachCoreTests", dependencies: ["CoachCore"], path: "Tests")
    ]
)
