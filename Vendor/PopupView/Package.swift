// swift-tools-version:5.6

import PackageDescription

let package = Package(
    name: "PopupView",
    platforms: [
        .iOS(.v15),
        .macOS(.v11),
        .tvOS(.v14),
        .watchOS(.v7)
    ],
    products: [
        .library(
            name: "PopupView",
            targets: ["PopupView"]
        )
    ],
    dependencies: [
        .package(path: "../swiftui-introspect")
    ],
    targets: [
        .target(
            name: "PopupView",
            dependencies: [
                .product(name: "SwiftUIIntrospect", package: "swiftui-introspect"),
            ]
        )
    ]
)
