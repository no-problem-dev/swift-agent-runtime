import Foundation
import ACPCore
import LLMClient

/// ACP の `session/update` 語彙に射影したエージェントループ拡張。
///
/// `session/update` は全エージェントステップを報告する標準的なテスト可能面であり、
/// クライアントが描画の唯一の情報源として使う想定。
/// ループの意味論イベント — thought・ツール呼び出し（`kind`・`rawInput`・可読 `title`）・
/// その結果（`content` + `rawOutput`）・message — を射影し、
/// ツール呼び出し ID を保持して更新を相関付ける。
///
/// コストは意味論イベントではない（`AgentEvent`/`AgentTelemetry` 参照）:
/// ステップごとのトークン使用量は `AgentTelemetry` metrics sink へ流れる。
/// ACP 対応物の `usage_update` は ACP 境界（`HostACPAgent`）で telemetry から射影され、
/// このイベント語彙からは射影しない — 意味論ストリームを metrics から切り離すため。
/// レンダリング済み system prompt は一切発行しない。
public extension AgentLoop {
    static func sessionUpdate(for event: Event) -> SessionUpdate? {
        switch event {
        case let .thinking(text):
            return .agentThoughtChunk(ContentChunk(content: .text(TextContent(text: text))))
        case let .toolCall(id, name, input):
            return .toolCall(ToolCall(
                toolCallId: ToolCallId(id),
                title: ACPToolMapping.title(forToolNamed: name),
                kind: ACPToolMapping.kind(forToolNamed: name),
                status: .inProgress,
                rawInput: ACPToolMapping.jsonValue(from: input)
            ))
        case let .toolResult(id, _, output, isError):
            return .toolCallUpdate(ToolCallUpdate(
                toolCallId: ToolCallId(id),
                status: isError ? .failed : .completed,
                content: [.content(Content(content: .text(TextContent(text: output))))],
                rawOutput: .string(output)
            ))
        case let .inputRequired(question):
            return .agentMessageChunk(ContentChunk(content: .text(TextContent(text: question))))
        case let .completed(text):
            return text.isEmpty ? nil : .agentMessageChunk(ContentChunk(content: .text(TextContent(text: text))))
        }
    }

    /// ループの進捗を ACP `session/update` のストリームとして返す。
    /// ACP ネイティブな面。`run(messages:onEvent:)` は telemetry（usage 内訳）も運ぶ詳細な内部射影として残る。
    func updates(messages: [LLMMessage]) -> AsyncThrowingStream<SessionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(messages: messages) { event in
                        if let update = Self.sessionUpdate(for: event) {
                            continuation.yield(update)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// ツール名を ACP `tool_call` の表示情報（kind + title）にマップし、生ツール入力を `JSONValue` にデコードする。
/// 名前ベースのヒューリスティックで動くため、ツールごとのレジストリなしに
/// ホスト委譲ツールもワーカーツールも扱える。
enum ACPToolMapping {
    /// ツール名 → ACP `ToolKind`。クライアントがアイコンを選ぶ用。未知の名前は `.other` にフォールバック。
    static func kind(forToolNamed name: String) -> ToolKind {
        let n = name.lowercased()
        // Sub-agent delegation: an opaque sub-agent invocation reads as "agent
        // reasoning" to the client (ACP has no dedicated delegate kind).
        if n.contains("send_message") || n.contains("delegate") || n.hasPrefix("agent") || n.contains("remote_agent") {
            return .think
        }
        if n.contains("search") { return .search }
        if n.contains("fetch") || n.contains("http") || n.contains("url") { return .fetch }
        if n.contains("delete") || n.contains("remove") { return .delete }
        if n.contains("move") || n.contains("rename") { return .move }
        if n.contains("write") || n.contains("edit") || n.contains("update") || n.contains("patch") || n.contains("create") { return .edit }
        if n.contains("read") || n.contains("get") || n.contains("list") || n.contains("inspect") { return .read }
        if n.contains("exec") || n.contains("run") || n.contains("script") || n.contains("bash") || n.contains("shell") { return .execute }
        return .other
    }

    /// ツール名 → 可読な `title`（例: `send_message` → "Send message"）。
    /// クライアントが独自にローカライズ可能。ワイヤ上のデフォルトとして妥当な値を提供する。
    static func title(forToolNamed name: String) -> String {
        let spaced = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let first = spaced.first else { return name }
        return first.uppercased() + spaced.dropFirst()
    }

    /// 生ツール呼び出し入力（JSON `Data`）を ACP `JSONValue` にデコードする。
    /// 入力が空か JSON として不正な場合は `nil` を返す。
    static func jsonValue(from input: Data) -> JSONValue? {
        guard !input.isEmpty else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: input)
    }
}
