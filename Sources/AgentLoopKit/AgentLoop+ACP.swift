import Foundation
import ACPCore
import LLMClient

/// The agent loop projected onto ACP's `session/update` vocabulary.
///
/// `session/update` is the standard, testable surface every agent step is
/// reported through, and it is intended to be the **single source of truth** a
/// client renders from. This projection maps the loop's *semantic* events:
/// thoughts, tool calls (with `kind`, `rawInput`, and a human-readable `title`),
/// their results (`content` + `rawOutput`), and messages — preserving tool-call
/// ids so updates correlate.
///
/// Cost is **not** a semantic event here (see `AgentEvent`/`AgentTelemetry`):
/// per-step token usage flows on the `AgentTelemetry` metrics sink. Its ACP
/// counterpart, `usage_update`, is projected from that telemetry at the ACP
/// boundary (`HostACPAgent`), not from this event vocabulary — keeping the
/// semantic stream free of metrics. The rendered system prompt is no longer
/// emitted at all.
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

    /// The loop's progress as a stream of ACP `session/update`s. This is the
    /// ACP-native surface; `run(messages:onEvent:)` remains the rich internal
    /// projection that also carries telemetry (usage breakdown).
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

/// Maps tool names to ACP `tool_call` presentation (kind + title) and decodes
/// raw tool input into a `JSONValue`. Heuristic and name-based so it works for
/// any agent's tools (host delegation tools and worker tools alike) without a
/// per-tool registry.
public enum ACPToolMapping {
    /// Tool name → ACP `ToolKind` so clients can pick an icon. Unknown names
    /// fall back to `.other`.
    public static func kind(forToolNamed name: String) -> ToolKind {
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

    /// Tool name → a human-readable `title` (e.g. `send_message` → "Send message").
    /// Clients may further localize; this keeps a sensible default on the wire.
    public static func title(forToolNamed name: String) -> String {
        let spaced = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let first = spaced.first else { return name }
        return first.uppercased() + spaced.dropFirst()
    }

    /// Decode raw tool-call input (JSON `Data`) into an ACP `JSONValue`.
    /// Returns `nil` when the input is empty or not valid JSON.
    public static func jsonValue(from input: Data) -> JSONValue? {
        guard !input.isEmpty else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: input)
    }
}
