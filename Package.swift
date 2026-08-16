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
        // Test-only support target. It is intentionally not exposed as a package product.
        .target(
            name: "QuizEngineTestSupport",
            dependencies: ["QuizEngineCore", "QuizEngineGame", "QuizEngineMultiplayer"],
            path: "Tests/QuizEngineTestSupport"
        ),
        .testTarget(
            name: "QuizEngineCoreTests",
            dependencies: ["QuizEngineCore", "QuizEngineTestSupport"],
            resources: [
                .process("Resources/alternate_questions.json"),
                // 60 questions split evenly across the three difficulties, so an
                // easy-to-hard ramp is measurable and distinguishable from a shuffle.
                .process("Resources/difficulty_ramp_questions.json"),
                // Historical persistence fixtures are copied verbatim, not processed.
                // `.process` flattens the directory tree, and the four v0.1.x releases
                // deliberately keep separate fixtures under identical file names, so
                // processing them collides. Copying also guarantees the committed bytes
                // are the bytes the migration tests hash.
                .copy("Resources/PersistenceFixtures"),
            ]
        ),
        .testTarget(name: "QuizEngineGameTests", dependencies: ["QuizEngineGame", "QuizEngineCore", "QuizEngineTestSupport"]),
        .testTarget(
            name: "QuizEngineMultiplayerTests",
            dependencies: ["QuizEngineMultiplayer", "QuizEngineCore", "QuizEngineTestSupport"]
        ),
    ]
)
