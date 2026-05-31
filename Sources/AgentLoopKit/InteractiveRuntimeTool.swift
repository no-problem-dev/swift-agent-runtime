import LLMClient
import LLMTool
import Foundation

/// 実行時にユーザー入力を要求する「対話ツール」を表すマーカープロトコル。
///
/// `AgentLoop` はこのプロトコルに準拠したツールが呼ばれると、`execute(with:)` を呼ばずに
/// ループを中断し、`question(from:)` の文言で `.inputRequired` を発する。これが A2A の
/// `TaskState.inputRequired` に写像され、ユーザー回答の再送で同一タスクが resume される。
public protocol InteractiveRuntimeTool: Tool {
    /// ツール引数からユーザーへの質問文を取り出す。
    func question(from argumentsData: Data) -> String
}

/// 標準の対話ツール。LLM が続行に追加情報を要するときに呼ぶ（a2a-samples の `require_user_input` 相当）。
public struct RequestUserInputTool: InteractiveRuntimeTool {
    public init() {}

    public var toolName: String { "request_user_input" }
    public var toolDescription: String {
        "Ask the user a clarifying question when you need more information to continue. "
            + "The task pauses until the user responds."
    }
    public var inputSchema: JSONSchema {
        .object(
            properties: ["question": .string(description: "The question to ask the user.")],
            required: ["question"]
        )
    }

    public func execute(with argumentsData: Data) async throws -> ToolResult {
        // 通常は AgentLoop が実行前に横取りする。横取りされなかった場合のフォールバック。
        .text(question(from: argumentsData))
    }

    public func question(from argumentsData: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any],
           let question = object["question"] as? String {
            return question
        }
        return String(data: argumentsData, encoding: .utf8) ?? ""
    }
}
