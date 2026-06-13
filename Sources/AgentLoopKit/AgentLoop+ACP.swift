import ACPCore
import LLMClient

/// The agent loop projected onto ACP's single event vocabulary.
///
/// `session/update` is the standard, testable surface every agent step is
/// reported through. Concepts ACP has no equivalent for — the rendered system
/// prompt and per-step token usage — are telemetry, not session updates, so the
/// projection drops them (they are carried on a separate channel). The semantic
/// stream (thought / tool_call / tool_call_update / message) maps faithfully,
/// preserving tool-call ids so updates correlate.
public extension AgentLoop {
    static func sessionUpdate(for event: Event) -> SessionUpdate? {
        switch event {
        case let .thinking(text):
            return .agentThoughtChunk(ContentChunk(content: .text(TextContent(text: text))))
        case let .toolCall(id, name):
            return .toolCall(ToolCall(toolCallId: ToolCallId(id), title: name, status: .inProgress))
        case let .toolResult(id, _, output, isError):
            return .toolCallUpdate(ToolCallUpdate(
                toolCallId: ToolCallId(id),
                status: isError ? .failed : .completed,
                content: [.content(Content(content: .text(TextContent(text: output))))]
            ))
        case let .inputRequired(question):
            return .agentMessageChunk(ContentChunk(content: .text(TextContent(text: question))))
        case let .completed(text):
            return text.isEmpty ? nil : .agentMessageChunk(ContentChunk(content: .text(TextContent(text: text))))
        }
    }

    /// The loop's progress as a stream of ACP `session/update`s. This is the
    /// ACP-native surface; `run(messages:onEvent:)` remains the rich internal
    /// projection that also carries telemetry (usage, system prompt).
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
