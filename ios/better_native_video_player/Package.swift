// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "better_native_video_player",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(
            name: "better-native-video-player",
            targets: ["better_native_video_player"]
        )
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "better_native_video_player",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("Resources")
            ],
            cSettings: [
                .headerSearchPath(".")
            ]
        )
    ]
)

