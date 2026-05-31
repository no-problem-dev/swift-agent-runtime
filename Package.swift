// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-agent-runtime",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        // 汎用: swift-llm-client だけに依存する自前エージェントループ（A2A 非依存）
        .library(name: "AgentLoopKit", targets: ["AgentLoopKit"]),
        // A2A 前提: オーケストレータ + ワーカーの実行環境
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
    ],
    dependencies: [
        // A2A プロトコル（client + server + in-process）。エージェント間の契約
        .package(path: "../swift-a2a"),
        // LLM プロバイダ抽象・Tool・SystemPrompt（ループは持たない＝ランタイムが自前実装）
        .package(path: "../swift-llm-client"),
    ],
    targets: [
        // 汎用エージェントループ層
        .target(
            name: "AgentLoopKit",
            dependencies: [
                .product(name: "LLMClient", package: "swift-llm-client"),
                .product(name: "LLMTool", package: "swift-llm-client"),
            ]
        ),
        // A2A オーケストレーション層
        .target(
            name: "AgentRuntime",
            dependencies: [
                "AgentLoopKit",
                .product(name: "A2ACore", package: "swift-a2a"),
                .product(name: "A2AServer", package: "swift-a2a"),
                .product(name: "A2AInProcess", package: "swift-a2a"),
                .product(name: "LLMClient", package: "swift-llm-client"),
                .product(name: "LLMTool", package: "swift-llm-client"),
            ]
        ),
        .testTarget(
            name: "AgentLoopKitTests",
            dependencies: ["AgentLoopKit"]
        ),
        .testTarget(
            name: "AgentRuntimeTests",
            dependencies: ["AgentRuntime"]
        ),
    ]
)
