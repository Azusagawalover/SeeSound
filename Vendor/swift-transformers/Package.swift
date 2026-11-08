// swift-tools-version: 5.8
// See Package.upstream.swift.txt for the original manifest. Runtime libraries only.
import PackageDescription
let package = Package(name: "swift-transformers", platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "Transformers", targets: ["Tokenizers", "Generation", "Models"])],
    targets: [
        .target(name: "Hub", resources: [.process("FallbackConfigs")]),
        .target(name: "Tokenizers", dependencies: ["Hub"]),
        .target(name: "TensorUtils"),
        .target(name: "Generation", dependencies: ["Tokenizers", "TensorUtils"]),
        .target(name: "Models", dependencies: ["Tokenizers", "Generation", "TensorUtils"])
    ])
