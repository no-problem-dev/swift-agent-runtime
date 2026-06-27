# swift-agent-runtime

LLM エージェントループと A2A/ACP オーケストレーション層を提供する Swift パッケージ。

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017+%20%7C%20macOS%2014+-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

## 概要

`swift-agent-runtime` は 2 つの責務をターゲットで分離して提供します。

- **`AgentLoopKit`** — A2A 非依存の汎用エージェントループ。`swift-llm-client` だけに依存し、LLM 呼び出し・ツール並列実行・`input-required` 中断・ACP `session/update` 射影を担う
- **`AgentRuntime`** — A2A を前提としたオーケストレーション層。`HostAgent`（委譲ループ型）・`RouterHostAgent`（パススルー型）・`LLMAgentExecutor`（ワーカー）・`HostACPAgent`（ACP 露出）を提供する

## アーキテクチャ

```
App / CLI
   ↕ ACP（縦境界）
HostACPAgent
   ↕
HostAgent / RouterHostAgent
   ↕ A2A（横境界）
AgentConnectionRegistry  →  Workers (LLMAgentExecutor)
                                  ↕
                            AgentLoop (AgentLoopKit)
                                  ↕
                         LLMClient (swift-llm-client)
```

| Product | 役割 | 主な依存 |
|---|---|---|
| `AgentLoopKit` | LLM 呼び出しループ + ACP 射影 | `swift-llm-client`, `swift-acp` |
| `AgentRuntime` | A2A オーケストレーション + ACP 露出 | `AgentLoopKit`, `swift-a2a`, `swift-acp` |

### AgentLoopKit の主な型

| 型 | 役割 |
|---|---|
| `AgentLoop<Client>` | ツール実行ループ本体（`run` / `events` / `updates`） |
| `AgentLoop.Event` | 意味論イベント（`thinking` / `toolCall` / `toolResult` / `inputRequired` / `completed`） |
| `AgentEvent` | `AgentLoop.Event` のクライアント非依存ミラー（型消去） |
| `AgentTelemetry` / `AgentTelemetrySink` | 側帯観測（`usage` / `systemPrompt` / `validationFailed`） |
| `UsageAccumulator` | ターン内トークン使用量の逐次集約器 |
| `InteractiveRuntimeTool` | 呼ばれるとループを中断して `inputRequired` を発するマーカープロトコル |
| `RequestUserInputTool` | 標準の対話ツール（`request_user_input`） |

### AgentRuntime の主な型

| 型 | 役割 |
|---|---|
| `HostAgent<Client>` | A2A ワーカーへ委譲するオーケストレータ。会話履歴を保持し `run` / `stream` を提供 |
| `RouterHostAgent<Client>` | 1 ワーカーへパススルー転送するルーター型オーケストレータ |
| `HostACPAgent<Client>` | `HostAgent` を ACP エージェントとして露出。セッション管理・会話永続化を担う |
| `LLMAgentExecutor<Client>` | `AgentLoop` を A2A `AgentExecutor` として実行するワーカー |
| `AgentConnectionRegistry` | ワーカー接続の登録・委譲・バックグラウンドタスク管理 |
| `AgentHistoryStore` / `InMemoryAgentHistoryStore` | ワーカーの LLM 会話履歴ストア（差し替え可能） |
| `DeliveryMode` | ワーカー応答の受け取り方（`streaming` / `blocking` / `polling`） |
| `BackgroundDelivery` | 非ブロッキング委譲の完了配信方式（`subscribe` / `push` / `pollInterval`） |

## インストール

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-agent-runtime.git", .upToNextMajor(from: "0.10.0"))
]
```

```swift
// ループだけ使う場合（A2A 非依存）
.target(name: "YourTarget", dependencies: [
    .product(name: "AgentLoopKit", package: "swift-agent-runtime"),
])

// A2A オーケストレーションも使う場合
.target(name: "YourTarget", dependencies: [
    .product(name: "AgentRuntime", package: "swift-agent-runtime"),
])
```

## クイックスタート

### AgentLoopKit — 単体エージェントループ

```swift
import AgentLoopKit

let loop = AgentLoop(
    client: myLLMClient,
    model: myModel,
    tools: ToolSet {
        MySearchTool()
        RequestUserInputTool()
    },
    systemPrompt: SystemPrompt(stringLiteral: "You are a helpful assistant."),
    maxSteps: 12
)

for try await event in loop.events(messages: [.user("今日の東京の天気は？")]) {
    switch event {
    case .thinking(let text):
        print("thinking: \(text)")
    case .toolCall(_, let name, _):
        print("calling tool: \(name)")
    case .toolResult(_, _, let output, let isError):
        print("tool result (error=\(isError)): \(output)")
    case .inputRequired(let question):
        print("needs user input: \(question)")
    case .completed(let text):
        print("completed: \(text)")
    }
}
```

テレメトリ（コスト計測）を受け取る場合:

```swift
let accumulator = UsageAccumulator()

let loop = AgentLoop(
    client: myLLMClient,
    model: myModel,
    telemetry: { telemetry in
        if case let .usage(usage, model) = telemetry {
            await accumulator.add(usage)
            print("[\(model)] input=\(usage.inputTokens) output=\(usage.outputTokens)")
        }
    }
)
```

### AgentRuntime — in-process ワーカーへ委譲する HostAgent

```swift
import AgentRuntime

// 1. ワーカーを登録
let registry = AgentConnectionRegistry()

let workerExecutor = LLMAgentExecutor(
    client: myLLMClient,
    model: myModel,
    systemPrompt: SystemPrompt(stringLiteral: "You are a research specialist."),
    maxSteps: 8
)
let workerCard = AgentCard(
    name: "researcher",
    description: "Searches and summarizes information on any topic."
)
await registry.register(card: workerCard, executor: workerExecutor)

// 2. HostAgent を作成してリクエストを投げる
let host = HostAgent(
    client: myLLMClient,
    model: myModel,
    registry: registry
)

let result = try await host.run("量子コンピューティングの最新動向を調べてまとめて")
print(result)

// ストリーミングで受け取る場合
for try await event in await host.stream("Swift Concurrency のベストプラクティスは？") {
    if case .completed(let text) = event { print(text) }
}
```

### バックグラウンド委譲（非ブロッキング）

```swift
// delegate_async: 即返し。ワーカーはバックグラウンドで実行継続
let handle = try await registry.delegateAsync(
    to: "researcher",
    text: "宇宙望遠鏡の最新データを分析して",
    delivery: .all   // subscribe + push + poll の3方式を同時使用
)
print("taskId=\(handle.taskId?.rawValue ?? "nil")")

// 後から確認
let status = try await registry.checkTask(handle.taskId!)
print("state=\(status.state), text=\(status.text)")

// 実行中タスク一覧
let running = await registry.listRunningTasks()
```

### RouterHostAgent — パススルー型ルーター

```swift
import AgentRuntime

let router = RouterHostAgent(
    client: myLLMClient,
    model: myModel,
    registry: registry,
    hooks: RouterHostAgent.Hooks(
        // LLM を介さない決定的ルーティング（例: userAction の surfaceId に基づく転送）
        preRoute: { parts in
            guard let text = parts.first?.text else { return nil }
            return text.contains("画像") ? "vision-agent" : nil
        }
    )
)

for try await event in await router.send([Part.text("この画像を解析して")]) {
    switch event {
    case .routed(let agent, let deterministic, _):
        print("routed to \(agent) (deterministic=\(deterministic))")
    case .worker(let streamResponse):
        // ワーカーの応答をそのままパススルー
        break
    }
}
```

### HostACPAgent — ACP 境界でのセッション管理

```swift
import AgentRuntime

let acpAgent = HostACPAgent(
    client: acpClient,
    telemetry: { telemetry in
        // コスト計測など
    },
    makeHost: {
        HostAgent(client: llmClient, model: model, registry: registry)
    }
)
// acpAgent は ACPAgent プロトコルを実装しており、ACP フレームワークに渡すだけで
// セッション管理・会話永続化（cwd/conversation.json）・マルチモーダル入力を処理する
```

## 対応プラットフォーム / 要件

| プラットフォーム | 最低バージョン |
|---|---|
| macOS | 14.0+ |
| iOS | 17.0+ |

- Swift 6.2+
- 依存: [swift-a2a](https://github.com/no-problem-dev/swift-a2a) 0.6.2+、[swift-llm-client](https://github.com/no-problem-dev/swift-llm-client) 3.7.0+、[swift-structured-data](https://github.com/no-problem-dev/swift-structured-data) 1.3.0+、[swift-acp](https://github.com/no-problem-dev/swift-acp) 0.1.0+

## ライセンス

MIT
