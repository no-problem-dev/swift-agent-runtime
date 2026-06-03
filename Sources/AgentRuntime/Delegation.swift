import A2ACore
import A2AClientCore
import LLMClient
import Foundation

/// ブロッキング委譲の集約結果（ワーカーのレポート本文＋終端状態＋トークン使用量）。
public struct DelegationResult: Sendable {
    public let text: String
    public let taskId: String?
    public let finalState: TaskState?
    /// ワーカーが消費したトークン使用量（artifact metadata から取得。無ければ nil）。
    public let usage: TokenUsage?

    public init(text: String, taskId: String?, finalState: TaskState?, usage: TokenUsage? = nil) {
        self.text = text
        self.taskId = taskId
        self.finalState = finalState
        self.usage = usage
    }
}

extension A2AClient {
    /// 1 メッセージをワーカーへ送り、配信モードに沿ってストリームを**終端まで消費**してから返す
    /// （a2a-samples `HostAgent.send_message` 相当のブロッキング委譲）。
    ///
    /// 待っている間の各 `StreamResponse` を `onEvent` に流すので、UI は進捗をライブ表示できる（SSE の本来の用途）。
    /// 呼び出しごとに新しい `messageId`（`taskId` 無し）で送るため、**同一ワーカーへの並列委譲も独立タスク**になる。
    /// artifact と Message 応答のテキストを集約して返す（status メッセージは進捗ノートなので含めない）。
    public func delegate(
        _ text: String,
        mode: DeliveryMode,
        onEvent: @Sendable (StreamResponse) async -> Void = { _ in }
    ) async throws -> DelegationResult {
        let message = Message(messageId: MessageID(UUID().uuidString), role: .user, parts: [.text(text)])
        var artifacts: [String: String] = [:]
        var messageText = ""
        var taskId: String?
        var finalState: TaskState?
        var usage: TokenUsage?

        for try await event in events(message, mode: mode) {
            await onEvent(event)
            switch event {
            case .task(let task):
                taskId = task.id.rawValue
                finalState = task.status.state
                for artifact in task.artifacts {
                    artifacts[artifact.artifactId.rawValue] = artifact.parts.compactMap(\.text).joined()
                    if let u = UsageMetadata.decode(artifact.metadata) { usage = u }
                }
            case .statusUpdate(let update):
                taskId = update.taskId.rawValue
                finalState = update.status.state
            case .artifactUpdate(let update):
                let id = update.artifact.artifactId.rawValue
                let chunk = update.artifact.parts.compactMap(\.text).joined()
                artifacts[id] = update.append ? (artifacts[id] ?? "") + chunk : chunk
                taskId = update.taskId.rawValue
                if let u = UsageMetadata.decode(update.artifact.metadata) { usage = u }
            case .message(let agentMessage):
                messageText += agentMessage.text
            }
        }

        let aggregated = (artifacts.values.joined(separator: "\n") + messageText)
        return DelegationResult(text: aggregated, taskId: taskId, finalState: finalState, usage: usage)
    }
}
