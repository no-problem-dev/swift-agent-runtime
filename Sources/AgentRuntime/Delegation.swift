import A2ACore
import A2AClientCore
import LLMClient
import Foundation

/// What a worker produced, once its stream reached the end.
public struct DelegationResult: Sendable {
    /// The worker's artifacts and message replies, concatenated. Progress notes are not included.
    public let text: String
    /// The task the worker opened, or `nil` if it answered with a bare message instead.
    public let taskId: String?
    /// The state the task ended in. `nil` means there was no task. Reaching the end of the stream
    /// is not the same as succeeding — check for `.completed` before trusting `text`.
    public let finalState: TaskState?
    /// What the worker spent, if it reported anything. `nil` when the worker sent no usage, or
    /// when the metadata failed to decode.
    public let usage: TokenUsage?

    public init(text: String, taskId: String?, finalState: TaskState?, usage: TokenUsage? = nil) {
        self.text = text
        self.taskId = taskId
        self.finalState = finalState
        self.usage = usage
    }
}

extension A2AClient {
    /// Sends one message to a worker and waits for its stream to end.
    ///
    /// Every event is handed to `onEvent` while the call is still blocked, which is how a UI shows
    /// progress without giving up the simple return value. Each call sends a fresh message with no
    /// task id, so two concurrent calls to the same worker get independent tasks and cannot
    /// interfere. Status messages are treated as progress notes and left out of the result text.
    ///
    /// - Parameters:
    ///   - text: The instruction for the worker.
    ///   - mode: How the reply is collected. All three modes block until the end either way.
    ///   - onEvent: Called for each event as it arrives, before this method returns.
    /// - Returns: The worker's artifacts and messages, its terminal state, and its usage.
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
