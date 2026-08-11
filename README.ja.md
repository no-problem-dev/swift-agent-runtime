# swift-agent-runtime

[English](./README.md) | 日本語

タスクが終わるまで自分のツールを呼び続ける LLM エージェントを作り、そうしたエージェント同士で仕事を渡し合わせる。

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017+%20%7C%20macOS%2014+-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

## 概要

書くのはツールとプロンプトだけ。1 ターンの進行はこのパッケージが回す — モデルを呼び、モデルが求めた
ツールを実行し、結果を返し、モデルが終わるか上限ステップに達したら止める。

- **ターンの進行がそのまま見える** — 思考・ツール呼び出し・ツール結果・完了がイベントとして届く。
  最後に文字列が 1 つ返るのではない
- **ツールは既定で並列に走る** — 切ればモデルが要求した順に 1 つずつ実行する
- **ツールが止まってユーザーに聞ける** — ループが中断して質問を表に出し、答えを受けて再開する。
  こちらで適当な値をでっち上げなくてよい
- **トークン使用量は側路で届く** — 費用の集計をツールのコードに通す必要がない
- **他のエージェントに委譲できる** — サブタスクをワーカーに渡して待つか、ハンドルだけ受け取って
  会話を続けたまま後で結果を回収する
- **必要な分だけ取れる** — `AgentLoopKit` はループ単体。`AgentRuntime` はその上にエージェント間の
  委譲とセッション管理を足す

## クイックスタート

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

for try await event in loop.events(messages: [.user("What is the weather in Tokyo today?")]) {
    switch event {
    case .thinking(let text):            print("thinking: \(text)")
    case .toolCall(_, let name, _):      print("calling tool: \(name)")
    case .toolResult(_, _, let out, let isError): print("result (error=\(isError)): \(out)")
    case .inputRequired(let question):   print("needs user input: \(question)")
    case .completed(let text):           print("completed: \(text)")
    }
}
```

サブタスクをワーカーエージェントに渡して答えを待つ:

```swift
import AgentRuntime

let registry = AgentConnectionRegistry()
await registry.register(
    card: AgentCard(name: "researcher", description: "Searches and summarizes any topic."),
    executor: LLMAgentExecutor(client: myLLMClient, model: myModel, maxSteps: 8)
)

let host = HostAgent(client: myLLMClient, model: myModel, registry: registry)
print(try await host.run("Research the latest trends in quantum computing."))
```

## ドキュメント

[**AgentLoopKit**](https://no-problem-dev.github.io/swift-agent-runtime/documentation/agentloopkit/) —
ループ本体、イベント、ツール、テレメトリ。

[**AgentRuntime**](https://no-problem-dev.github.io/swift-agent-runtime/documentation/agentruntime/) —
エージェント間の委譲、バックグラウンドタスク、ACP でのホスト公開。

## インストール

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-agent-runtime.git", .upToNextMinor(from: "0.20.0"))
]
```

必要なプロダクトを追加する。`AgentLoopKit` はエージェント間通信への依存を持たない:

```swift
.product(name: "AgentLoopKit", package: "swift-agent-runtime"),   // ループのみ
.product(name: "AgentRuntime", package: "swift-agent-runtime"),   // ループ + 委譲
```

## 要件

- iOS 17.0+ / macOS 14.0+
- Swift 6.2+

## ライセンス

MIT — [LICENSE](LICENSE) を参照。
