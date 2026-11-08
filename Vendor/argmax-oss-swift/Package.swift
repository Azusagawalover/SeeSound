// swift-tools-version: 5.9
// See Package.upstream.swift.txt for the original manifest. Runtime library only.
import PackageDescription
let package = Package(name: "whisperkit", platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "WhisperKit", targets: ["WhisperKit"])],
    dependencies: [.package(path: "../swift-transformers")],
    targets: [.target(name: "WhisperKit", dependencies: [.product(name: "Transformers", package: "swift-transformers")])])
