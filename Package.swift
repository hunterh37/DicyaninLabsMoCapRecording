// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DicyaninLabsMoCapRecording",
    platforms: [
        .iOS(.v18),
        .visionOS(.v1),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DicyaninLabsMoCapRecording",
            targets: ["DicyaninLabsMoCapRecording"]
        )
    ],
    targets: [
        .target(
            name: "DicyaninLabsMoCapRecording",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "DicyaninLabsMoCapRecordingTests",
            dependencies: ["DicyaninLabsMoCapRecording"]
        )
    ]
)
