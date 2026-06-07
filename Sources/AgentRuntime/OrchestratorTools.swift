import A2ACore
import LLMClient
import LLMTool
import Foundation

/// 委譲先リモートエージェントを列挙するツール（a2a-samples `list_remote_agents` 相当）。
/// root instruction が `list_remote_agents` を名指しするため、ツール名はそれに一致させる。
public struct ListRemoteAgentsTool: Tool {
    private let registry: AgentConnectionRegistry

    public init(registry: AgentConnectionRegistry) {
        self.registry = registry
    }

    public var toolName: String { "list_remote_agents" }
    public var toolDescription: String {
        "List the available remote agents you can use to delegate the task. Returns each agent's name and description."
    }
    public var inputSchema: JSONSchema {
        .object(properties: [:])
    }

    public func execute(with argumentsData: Data) async throws -> ToolResult {
        let agents = await registry.descriptors()
        let data = try JSONEncoder().encode(agents)
        return .json(data)
    }
}

/// リモートエージェントへメッセージを送って行動させ、応答を得るツール（a2a-samples `send_message` 相当）。
/// 引数は公式と同じく `agent_name` / `message`。
public struct SendMessageTool: Tool {
    private let registry: AgentConnectionRegistry

    public init(registry: AgentConnectionRegistry) {
        self.registry = registry
    }

    private struct Arguments: Decodable {
        let agent_name: String
        let message: String
    }

    public var toolName: String { "send_message" }
    public var toolDescription: String {
        "Send a message to exactly ONE remote agent by name to take action, and get its response. "
            + "Include the agent name from list_remote_agents. Call this tool once per agent."
    }
    public var inputSchema: JSONSchema {
        .object(
            properties: [
                "agent_name": .string(description: "The name of a single agent to send the task to (never a comma-separated list)."),
                "message": .string(description: "The message/instruction to send to the agent."),
            ],
            required: ["agent_name", "message"]
        )
    }

    public func execute(with argumentsData: Data) async throws -> ToolResult {
        let arguments = try JSONDecoder().decode(Arguments.self, from: argumentsData)
        let outcome = try await registry.send(to: arguments.agent_name, text: arguments.message)

        switch outcome.state {
        case .failed:
            return .error("Agent \(outcome.agentName) failed: \(outcome.text)")
        case .canceled, .rejected:
            return .error("Agent \(outcome.agentName) did not complete (\(outcome.state?.rawValue ?? "")): \(outcome.text)")
        case .inputRequired, .authRequired:
            let question = outcome.text.isEmpty ? "(no prompt provided)" : outcome.text
            return .text("Agent \(outcome.agentName) needs more input before it can continue. "
                + "Ask the user: \(question)")
        default:
            if outcome.text.isEmpty {
                let stateLabel = outcome.state.map { $0.rawValue } ?? "ok"
                return .text("Agent \(outcome.agentName) responded (\(stateLabel)) with no text.")
            }
            return .text(outcome.text)
        }
    }
}
