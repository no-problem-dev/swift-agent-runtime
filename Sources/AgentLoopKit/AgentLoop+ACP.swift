import Foundation
import ACPCore
import LLMClient

/// Projects loop events onto the ACP `session/update` vocabulary.
///
/// A client can render from these updates alone: thoughts, tool calls (with a kind, a readable
/// title and the raw input), their results, and messages. Tool call ids are carried through, so a
/// call and its later update correlate.
///
/// Token usage is deliberately absent. Its ACP counterpart, `usage_update`, is projected from the
/// telemetry sink at the ACP boundary instead, which keeps this stream free of metrics. The
/// rendered system prompt is never emitted at all.
public extension AgentLoop {
    /// Maps one event to its ACP update, or `nil` for events with no ACP counterpart.
    static func sessionUpdate(for event: Event) -> SessionUpdate? {
        switch event {
        case let .textDelta(delta):
            // ACP chunks are incremental, and every step's text is guaranteed to arrive as deltas
            // (a non-streaming provider still sends one whole-text delta), so this is the only
            // place text is projected.
            return .agentMessageChunk(ContentChunk(content: .text(TextContent(text: delta))))
        case let .thinkingDelta(delta):
            return .agentThoughtChunk(ContentChunk(content: .text(TextContent(text: delta))))
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
        case let .toolApprovalRequired(_, _, _, request):
            // ACP has no approval vocabulary, so the summary is shown as an agent message.
            // A client driven only by these updates therefore has no way to send a verdict back.
            return .agentMessageChunk(ContentChunk(content: .text(TextContent(text: request.summary))))
        case let .inputRequired(question):
            return .agentMessageChunk(ContentChunk(content: .text(TextContent(text: question))))
        case .completed:
            // The deltas already carried the whole text; projecting it again would show it twice.
            return nil
        }
    }

    /// Runs the loop and streams its progress as ACP updates.
    ///
    /// The work happens in an unstructured task, so this does not inherit the caller's
    /// cancellation — terminating the stream is what stops the loop. Nothing here reports token
    /// usage; use `run(messages:onEvent:)` with a telemetry sink when that is needed.
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

/// Derives a tool call's ACP display information from its name alone.
///
/// Working from the name means delegation tools and worker tools are both covered without any
/// per-tool registration — at the cost of guessing, so an unusual name gets a generic kind.
enum ACPToolMapping {
    /// Picks the icon category a client shows for a tool. Unrecognised names fall back to `.other`.
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

    /// Turns a tool name into a readable label, for example `send_message` into "Send message".
    /// English only — a client that needs another language should localise from the tool name.
    static func title(forToolNamed name: String) -> String {
        let spaced = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let first = spaced.first else { return name }
        return first.uppercased() + spaced.dropFirst()
    }

    /// Decodes the raw tool arguments for display. Returns `nil` when the input is empty or not
    /// valid JSON — the update is still sent, just without its raw input.
    static func jsonValue(from input: Data) -> JSONValue? {
        guard !input.isEmpty else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: input)
    }
}
