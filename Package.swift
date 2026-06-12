// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ToshLLM",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ToshLLM", path: "Sources"),
        .testTarget(name: "ToshLLMTests", dependencies: ["ToshLLM"], path: "Tests"),
    ]
)
