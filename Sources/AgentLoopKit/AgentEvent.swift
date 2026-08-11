import LLMTool
import Foundation
import LLMClient
import LLMAgentStep

/// The loop's events without the client type — use this to store or pass them across a boundary.
///
/// `AgentLoop` is generic over its client, so its nested `Event` cannot be named without also
/// naming a client type. This mirror can. It lives in the same module as the original because the
/// conversion below switches exhaustively: a case added there stops compiling here.
/// Token usage and rendered prompts are not mirrored — those are already client-independent.
public enum AgentEvent: Sendable {
    /// The next chunk of assistant text. Render from these; the text on `completed` repeats the
    /// same content for history, so displaying both duplicates it.
    case textDelta(String)
    /// The next chunk of reasoning text. Only arrives when thinking is enabled.
    case thinkingDelta(String)
    /// A tool the model asked to run. `input` is the raw JSON arguments, unparsed.
    case toolCall(id: String, name: String, input: Data)
    /// A finished tool call. `isError` is fed back to the model to recover from, not thrown.
    case toolResult(id: String, name: String, output: String, isError: Bool)
    /// A tool needing approval was requested; the loop stopped without running any of that batch.
    case toolApprovalRequired(id: String, name: String, input: Data, request: ToolApprovalRequest)
    /// The agent asked the user a question and stopped.
    case inputRequired(question: String)
    /// The turn ended. Also emitted with empty text when the step budget ran out.
    case completed(text: String)
}

extension AgentEvent {
    /// Erases the client type from a loop event.
    public init<C: AgentCapableClient>(_ event: AgentLoop<C>.Event) where C.Model: Sendable {
        switch event {
        case .textDelta(let delta): self = .textDelta(delta)
        case .thinkingDelta(let delta): self = .thinkingDelta(delta)
        case .toolCall(let id, let name, let input): self = .toolCall(id: id, name: name, input: input)
        case .toolResult(let id, let name, let output, let isError):
            self = .toolResult(id: id, name: name, output: output, isError: isError)
        case .toolApprovalRequired(let id, let name, let input, let request):
            self = .toolApprovalRequired(id: id, name: name, input: input, request: request)
        case .inputRequired(let question): self = .inputRequired(question: question)
        case .completed(let text): self = .completed(text: text)
        }
    }
}
