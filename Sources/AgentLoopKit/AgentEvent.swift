import LLMTool
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
    /// アシスタントテキストの増分。表示はデルタを正とし、`completed` の `text` は
    /// ターン終端の確定値として扱う。
    case textDelta(String)
    /// 思考テキストの増分（thinking 有効時のみ）。
    case thinkingDelta(String)
    case toolCall(id: String, name: String, input: Data)
    case toolResult(id: String, name: String, output: String, isError: Bool)
    /// 承認必須ツールの呼び出し(ループは実行せずに中断している)。
    case toolApprovalRequired(id: String, name: String, input: Data, request: ToolApprovalRequest)
    case inputRequired(question: String)
    case completed(text: String)
}

extension AgentEvent {
    /// ジェネリックな `AgentLoop<C>.Event` を非ジェネリックな `AgentEvent` へ型消去する。
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
