// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Chess",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ChessCore", path: "Sources/ChessCore"),
        .target(name: "ChessEngine", dependencies: ["ChessCore"], path: "Sources/ChessEngine"),
        .target(name: "ChessCoach", dependencies: ["ChessCore", "ChessEngine"], path: "Sources/ChessCoach"),
        .executableTarget(name: "ChessApp", dependencies: ["ChessCore", "ChessEngine", "ChessCoach"], path: "Sources/ChessApp"),
        .testTarget(name: "ChessCoreTests", dependencies: ["ChessCore"], path: "Tests/ChessCoreTests"),
        .testTarget(name: "ChessAppTests", dependencies: ["ChessApp", "ChessCore", "ChessEngine"], path: "Tests/ChessAppTests"),
        .testTarget(name: "ChessCoachTests", dependencies: ["ChessCore", "ChessEngine", "ChessCoach"], path: "Tests/ChessCoachTests"),
        .testTarget(name: "ChessEngineTests", dependencies: ["ChessCore", "ChessEngine"], path: "Tests/ChessEngineTests"),
    ]
)
