// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DicyaninLabsMoCapRecording",
    platforms: [
        .iOS(.v17),
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
            name: "DicyaninLabsMoCapRecording"
        ),
        .testTarget(
            name: "DicyaninLabsMoCapRecordingTests",
            dependencies: ["DicyaninLabsMoCapRecording"]
        )
    ]
)
