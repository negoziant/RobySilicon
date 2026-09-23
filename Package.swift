// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Roby",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ResourceKit", targets: ["ResourceKit"]),
        .executable(name: "RobyTool", targets: ["RobyTool"]),
        .executable(name: "Roby", targets: ["Roby"]),
    ],
    targets: [
        .target(name: "ResourceKit"),
        .executableTarget(name: "RobyTool", dependencies: ["ResourceKit"]),
        .executableTarget(name: "Roby", dependencies: ["ResourceKit"]),
    ]
)
