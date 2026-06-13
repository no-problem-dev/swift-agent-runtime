import Foundation
import LLMClient
import LLMAgentStep

/// `AgentLoop.Event`（意味論イベント）の Client 非依存な射影。
///
/// `AgentLoop` はクライアント型でジェネリックなため、その `Event` は型引数なしに
/// 名前を呼べない。これはホスト／アプリが消費するための非ジェネリックなミラーで、
/// `Event` と同一モジュールに置く — 追従漏れは runtime のビルドで検知される。
/// 側帯観測（usage/systemPrompt 等）は `AgentTelemetry`（非ジェネリック）を直接使う。
public enum AgentEvent: Sendable {
    case thinking(String)
    case toolCall(id: String, name: String, input: Data)
    case toolResult(id: String, name: String, output: String, isError: Bool)
    case inputRequired(question: String)
    case completed(text: String)
}

extension AgentEvent {
    /// ジェネリックな `AgentLoop<C>.Event` を非ジェネリックな `AgentEvent` へ型消去する。
    public init<C: AgentCapableClient>(_ event: AgentLoop<C>.Event) where C.Model: Sendable {
        switch event {
        case .thinking(let text): self = .thinking(text)
        case .toolCall(let id, let name, let input): self = .toolCall(id: id, name: name, input: input)
        case .toolResult(let id, let name, let output, let isError):
            self = .toolResult(id: id, name: name, output: output, isError: isError)
        case .inputRequired(let question): self = .inputRequired(question: question)
        case .completed(let text): self = .completed(text: text)
        }
    }
}
