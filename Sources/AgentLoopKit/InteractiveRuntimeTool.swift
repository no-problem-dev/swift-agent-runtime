import LLMClient
import LLMTool
import Foundation

/// Marks a tool that stops the turn to ask the user something.
///
/// The loop never calls `execute` on one of these. When the model requests it, the loop reports
/// the question and returns, so anything the tool body would do will not happen.
public protocol InteractiveRuntimeTool: Tool {
    /// Extracts the question to show the user from the model's raw arguments.
    /// Called instead of executing the tool, so it must not have side effects.
    func question(from argumentsData: Data) -> String
}

/// The stock way to let a model ask the user a clarifying question and pause the turn.
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
