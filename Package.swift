// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Pomo",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Pomo", targets: ["Pomo"])
    ],
    targets: [
        .executableTarget(
            name: "Pomo",
            path: "Sources/Pomo"
        ),
        .testTarget(
            name: "PomoTests",
            dependencies: ["Pomo"],
            path: "Tests/PomoTests"
        )
    ]
)
