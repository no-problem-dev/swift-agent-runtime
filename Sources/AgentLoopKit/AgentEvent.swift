import LLMClient
import LLMAgentStep

/// `AgentLoop.Event` の Client 非依存な射影。
///
/// `AgentLoop` はクライアント型でジェネリックなため、その `Event` は型引数なしに
/// 名前を呼べない。これはホスト／アプリが消費するための非ジェネリックなミラーで、
/// `Event` と同一モジュールに置く — 追従漏れは runtime のビルドで検知される。
public enum AgentEvent: Sendable {
    case systemPrompt(rendered: String)
    case thinking(String)
    case toolCall(id: String, name: String)
    case toolResult(id: String, name: String, output: String, isError: Bool)
    case inputRequired(question: String)
    case completed(text: String)
    case usage(TokenUsage, model: String)
    case validationFailed(issues: [String], willRetry: Bool)
}

extension AgentEvent {
    /// ジェネリックな `AgentLoop<C>.Event` を非ジェネリックな `AgentEvent` へ型消去する。
    public init<C: AgentCapableClient>(_ event: AgentLoop<C>.Event) where C.Model: Sendable {
        switch event {
        case .systemPrompt(let rendered): self = .systemPrompt(rendered: rendered)
        case .thinking(let text): self = .thinking(text)
        case .toolCall(let id, let name): self = .toolCall(id: id, name: name)
        case .toolResult(let id, let name, let output, let isError):
            self = .toolResult(id: id, name: name, output: output, isError: isError)
        case .inputRequired(let question): self = .inputRequired(question: question)
        case .completed(let text): self = .completed(text: text)
        case .usage(let usage, let model): self = .usage(usage, model: model)
        case .validationFailed(let issues, let willRetry):
            self = .validationFailed(issues: issues, willRetry: willRetry)
        }
    }
}
