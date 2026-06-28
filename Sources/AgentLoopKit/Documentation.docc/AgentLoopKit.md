# ``AgentLoopKit``

全エージェントに共通する LLM ステップ実行エンジン — ツール呼び出し・並列実行・ACP session/update 射影を担う自律ループ基盤。

## Overview

`AgentLoopKit` はパッケージの最下層に位置する実行エンジンです。LLM クライアント（`AgentCapableClient`）とツール群（`ToolSet`）を受け取り、LLM 推論 → ツール呼び出し → 結果フィードバックのサイクルを `maxSteps` 回まで回します。ループが終了すると最終テキストと全トランスクリプト（tool call / tool result を含む `[LLMMessage]`）を返します。

上位の `AgentRuntime` モジュールは `HostAgent`・`LLMAgentExecutor`・`RouterHostAgent` でこの基盤ループを内部的に使います。A2A フリートへの委譲・会話管理・ACP ゲートウェイが必要な場合は `AgentRuntime` を import してください。

### 基本的な使い方

```swift
import AgentLoopKit

let loop = AgentLoop(
    client: myClient,
    model: myModel,
    tools: ToolSet { SearchTool() },
    systemPrompt: SystemPrompt(stringLiteral: "You are a helpful assistant."),
    maxSteps: 12
)

// ループを実行し、意味論イベントをコールバックで受け取る
let transcript = try await loop.run(messages: [.user("Swift の最新動向は？")]) { event in
    switch event {
    case .thinking(let text):
        print("💭 \(text)")
    case .toolCall(_, let name, _):
        print("🔧 \(name)")
    case .toolResult(let id, let name, let output, let isError):
        print(isError ? "⚠️ \(name): \(output)" : "✅ \(name)")
    case .inputRequired(let question):
        print("❓ \(question)")
    case .completed(let text):
        print(text)
    }
}
// `transcript` をそのまま次ターンの `messages` に渡すと会話が継続する
```

### ストリーミングで使う

`events(messages:)` を使うと同じイベントを `AsyncThrowingStream` で受け取れます。複数ループを並行実行したい場合や、別 `Task` でキャンセル制御したい場合に適しています。

```swift
import AgentLoopKit

let loop = AgentLoop(client: myClient, model: myModel, tools: myTools)

for try await event in loop.events(messages: history) {
    switch event {
    case .completed(let text): renderFinalResponse(text)
    default: break
    }
}
```

### ACP への射影

ACP 統合が必要な場面では `updates(messages:)` を使います。`AgentLoop.Event` を ACP 標準語彙（`session/update`）に射影したストリームを直接返し、クライアントへそのまま流せます。

```swift
import AgentLoopKit

let loop = AgentLoop(client: myClient, model: myModel, tools: myTools)

for try await update in loop.updates(messages: history) {
    try await acpClient.sessionUpdate(
        SessionNotification(sessionId: sessionId, update: update)
    )
}
```

### テレメトリ（コスト計測・デバッグ観測）

`AgentLoop.Event` は意味論イベントのみを保持します。トークン使用量・レンダリング済み system prompt などのコスト計測・デバッグ情報は `AgentTelemetrySink` で別経路に分離します。

```swift
import AgentLoopKit

let accumulator = UsageAccumulator()

let loop = AgentLoop(
    client: myClient,
    model: myModel,
    tools: myTools,
    telemetry: { event in
        if case let .usage(usage, model) = event {
            await accumulator.add(usage)
        }
    }
)

_ = try await loop.run(messages: history) { _ in }
let total = await accumulator.total
print("Total tokens: \(total?.inputTokens ?? 0) in / \(total?.outputTokens ?? 0) out")
```

### 対話ツール

`InteractiveRuntimeTool` を実装したツールを `ToolSet` に追加すると、LLM がそのツールを呼んだ瞬間にループが中断し `.inputRequired` イベントが発火します。標準実装の `RequestUserInputTool` を使うと、LLM がユーザーへの質問内容を自由に記述できます。

```swift
import AgentLoopKit

let loop = AgentLoop(
    client: myClient,
    model: myModel,
    tools: ToolSet { RequestUserInputTool() },
    maxSteps: 8
)

_ = try await loop.run(messages: [.user("ファイルを削除してください")]) { event in
    if case .inputRequired(let question) = event {
        // ループが中断し、LLM が生成した確認質問を受け取る
        print("LLM asks: \(question)")
    }
}
```

## Topics

### エージェントループ

- ``AgentLoop``

### イベント

- ``AgentEvent``

### テレメトリ

- ``AgentTelemetry``
- ``AgentTelemetrySink``
- ``UsageAccumulator``

### 対話ツール

- ``InteractiveRuntimeTool``
- ``RequestUserInputTool``
