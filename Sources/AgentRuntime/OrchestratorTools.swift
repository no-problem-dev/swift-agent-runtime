import A2ACore
import LLMClient
import LLMTool
import Foundation

/// オーケストレータが委譲先を列挙するツール（a2a-samples `list_remote_agents` 相当）。
public struct ListAgentsTool: Tool {
    private let registry: AgentConnectionRegistry

    public init(registry: AgentConnectionRegistry) {
        self.registry = registry
    }

    public var toolName: String { "list_agents" }
    public var toolDescription: String {
        "List the available remote agents you can delegate tasks to. Returns each agent's name and description."
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

/// オーケストレータが指定ワーカーへ委譲するツール（a2a-samples `send_message` 相当）。
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
        "Send a message to a remote agent by name to take action, and get its response. Include the agent name from list_agents."
    }
    public var inputSchema: JSONSchema {
        .object(
            properties: [
                "agent_name": .string(description: "The name of the agent to delegate the task to."),
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
            // ワーカーが続行に追加入力を要求している。オーケストレータはこれをユーザーへ
            // 問い返し、得た回答を同じ send_message で同ワーカーへ再送する（同一 task に継続）。
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
