# ``AgentRuntime``

A2A 前提のオーケストレータ＋ワーカー実行環境 — 複数の専門ワーカーエージェントへの委譲・並列実行・ACP ゲートウェイをパッケージルートとして提供する Swift ランタイム。

## Overview

`AgentRuntime` は `swift-agent-runtime` の中核ライブラリです。import 1 つでホストエージェントの構築からワーカーの登録・A2A 委譲・ACP ゲートウェイまで揃います。`AgentLoopKit` の `AgentLoop` をステップ実行エンジンとして内包し、委譲・会話管理・A2A プロトコル変換はこの層が担います。

`AgentLoopKit` はループの基盤（LLM ステップ・ツール実行・ACP 射影）のみを提供します。A2A フリートへの並列委譲・セッション管理・ACP ゲートウェイが必要な場合は、`AgentRuntime`（このモジュール）を import してください。`AgentLoopKit`・`A2ACore`・`LLMClient`・`LLMTool` は `AgentRuntime` が再エクスポートするため、追加 import は不要です。

### HostAgent — オーケストレータ

`HostAgent` は A2A フリートを束ねるオーケストレータです。`AgentConnectionRegistry` に登録されたワーカーに対し、`send_message`（ブロッキング委譲）または `delegate_async`（並列バックグラウンド委譲）でタスクを振り分け、最終応答を合成します。会話履歴をターンをまたいで自動保持し、`run(_:)` と `stream(_:telemetry:)` の両方で利用できます。

```swift
import AgentRuntime

// ワーカーを登録する
let registry = AgentConnectionRegistry()
await registry.register(
    card: AgentCard(name: "researcher", description: "Web research specialist"),
    executor: LLMAgentExecutor(
        client: myClient,
        model: myModel,
        tools: ToolSet { WebSearchTool() }
    )
)

// ホストを構築する
let host = HostAgent(client: myClient, model: myModel, registry: registry)

// テキスト入力を処理する（会話履歴は自動保持）
let response = try await host.run("Swift の最新動向を調べてください")
print(response)

// 次のターンも同じ `host` を使うと文脈が引き継がれる
let followUp = try await host.run("その中で iOS 開発に直接関係するものは？")
print(followUp)
```

### RouterHostAgent — ルーティング専用ホスト

`RouterHostAgent` は「集約して自分で合成する」`HostAgent` と異なり、受信メッセージをちょうど 1 ワーカーへ転送してその応答をパススルーします。専門ワーカーへのドメイン知識なしのルーティングを実現し、A2UI スタイルのオーケストレーションに適しています。`Hooks`（`preRoute` / `prepareOutbound` / `observeWorkerParts`）で判定ロジックとメタデータ変換を注入します。

### ACP ゲートウェイ

`HostACPAgent` は `HostAgent` を ACP エージェント境界として公開します。アプリ（ACP クライアント）は `prompt` でホストを駆動し、ホストは内部で A2A ワーカーに委譲します。セッションごとに `HostAgent` インスタンスを保持して会話を分離し、会話履歴を `cwd/conversation.json` に自動永続化することで `session/load` による再開をサポートします。

### LLMAgentExecutor — ワーカー

`LLMAgentExecutor` は単一の LLM エージェントを A2A の `AgentExecutor` として包むワーカーです。`AgentLoop` を内部で実行し、working → artifact → completed の A2A タスクライフサイクルを自動管理します。`AgentHistoryStore` を注入すると、コンテキスト ID 単位でネイティブ会話履歴（tool call / tool result 込みの `[LLMMessage]`）を維持できます。

```swift
import AgentRuntime

// ワーカーの会話履歴を永続化する（コンテキスト ID 単位）
let historyStore = InMemoryAgentHistoryStore()

let executor = LLMAgentExecutor(
    client: myClient,
    model: myModel,
    tools: ToolSet { FileReadTool() },
    systemPrompt: SystemPrompt(stringLiteral: "You are a file analysis specialist."),
    historyStore: historyStore
)

let registry = AgentConnectionRegistry()
await registry.register(card: myAgentCard, executor: executor)
```

### 非ブロッキング委譲（バックグラウンドエージェント）

`AgentConnectionRegistry.delegateAsync(to:text:delivery:)` は A2A `returnImmediately` でタスクを生成して即ハンドルを返します。ワーカーはサーバ側でバックグラウンド実行を継続し、ホストは `checkTask(_:)` / `listRunningTasks()` で後から状況・成果物を確認できます。

`BackgroundDelivery` で完了の受け取り方（SSE subscribe / poll / push）を組み合わせます。既定の `.all`（subscribe + push + 2 分ごと poll）が最も堅牢です。

### 配信モード

`DeliveryMode` はワーカー応答の受け取り方を制御します。`.streaming`（SSE / `message/stream`）はリアルタイムに status・artifact を受信し、`.blocking`（`message/send`）は終端まで待って 1 回返ります。`.polling`（`returnImmediately` + `tasks/get`）は非ブロッキング送信後にポーリングで追いかけます。

## Topics

### ホストエージェント

- ``HostAgent``
- ``HostAgentExecutor``
- ``HostACPAgent``
- ``HostACPAgentError``
- ``RouterHostAgent``

### ワーカー実行

- ``LLMAgentExecutor``
- ``AgentHistoryStore``
- ``InMemoryAgentHistoryStore``

### 接続レジストリ

- ``AgentConnectionRegistry``
- ``AgentDescriptor``
- ``AgentSendOutcome``
- ``AgentTaskHandle``
- ``AgentTaskStatus``

### 非同期委譲

- ``BackgroundDelivery``
- ``DelegationEvent``
- ``DelegationObserver``
- ``DelegationUsageObserver``
- ``DelegationResult``

### 配信モード

- ``DeliveryMode``

### 委譲ツール

- ``ListRemoteAgentsTool``
- ``SendMessageTool``
- ``DelegateAsyncTool``
- ``CheckTaskTool``
- ``ListRunningTasksTool``

### エラー

- ``AgentRuntimeError``
