// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuizEngine",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "QuizEngineCore", targets: ["QuizEngineCore"]),
        .library(name: "QuizEngineGame", targets: ["QuizEngineGame"]),
        .library(name: "QuizEngineMultiplayer", targets: ["QuizEngineMultiplayer"]),
    ],
    targets: [
        .target(name: "QuizEngineCore", path: "Sources/QuizEngineCore"),
        .target(name: "QuizEngineGame", dependencies: ["QuizEngineCore"], path: "Sources/QuizEngineGame"),
        .target(name: "QuizEngineMultiplayer", dependencies: ["QuizEngineCore"], path: "Sources/QuizEngineMultiplayer"),
        .testTarget(
            name: "QuizEngineCoreTests",
            dependencies: ["QuizEngineCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "QuizEngineGameTests", dependencies: ["QuizEngineGame", "QuizEngineCore"]),
    ]
)
