import LLMClient
import LLMTool
import Foundation

/// 呼ばれると `AgentLoop` がループを中断し `.inputRequired` を発する対話ツールのマーカー。
public protocol InteractiveRuntimeTool: Tool {
    func question(from argumentsData: Data) -> String
}

/// 標準の対話ツール（a2a-samples の `require_user_input` 相当）。
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
