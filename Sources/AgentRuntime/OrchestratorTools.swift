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

/// リモートエージェントへ**非ブロッキング**で委譲し、完了を待たず即 task_id を返すツール
/// （A2A `returnImmediately`）。複数エージェントを並列に走らせ、後から `check_task` /
/// `list_running_tasks` で進捗・成果物を確認するバックグラウンドエージェント運用の起点。
public struct DelegateAsyncTool: Tool {
    private let registry: AgentConnectionRegistry

    public init(registry: AgentConnectionRegistry) {
        self.registry = registry
    }

    private struct Arguments: Decodable {
        let agent_name: String
        let message: String
    }

    public var toolName: String { "delegate_async" }
    public var toolDescription: String {
        "Delegate a task to exactly ONE remote agent and return IMMEDIATELY with a task_id, "
            + "WITHOUT waiting for it to finish. Use this to start multiple agents working in parallel. "
            + "You do NOT have to wait for it within this turn — you may respond to the user now and the task "
            + "keeps running in the background; its completion is delivered automatically. "
            + "Use check_task to fetch a result on demand, or list_running_tasks to see what is still in flight."
    }
    public var inputSchema: JSONSchema {
        .object(
            properties: [
                "agent_name": .string(description: "The name of a single agent to delegate to (from list_remote_agents)."),
                "message": .string(description: "The message/instruction to send to the agent."),
            ],
            required: ["agent_name", "message"]
        )
    }

    public func execute(with argumentsData: Data) async throws -> ToolResult {
        let arguments = try JSONDecoder().decode(Arguments.self, from: argumentsData)
        let handle = try await registry.delegateAsync(to: arguments.agent_name, text: arguments.message)
        guard let taskId = handle.taskId else {
            // ワーカーがタスクを作らず Message を即返した（同期完了）。
            return .text(handle.immediateText.isEmpty
                ? "Agent \(handle.agentName) responded immediately with no text."
                : handle.immediateText)
        }
        let state = handle.state?.rawValue ?? "submitted"
        return .text("Started agent \(handle.agentName) in the background. "
            + "task_id=\(taskId.rawValue), state=\(state). "
            + "It keeps running; use check_task with this task_id to get its result, or list_running_tasks to see all in-flight tasks.")
    }
}

/// 委譲済みタスクの現在状態と成果物を `task_id` で取得するツール（A2A `tasks/get`）。
public struct CheckTaskTool: Tool {
    private let registry: AgentConnectionRegistry

    public init(registry: AgentConnectionRegistry) {
        self.registry = registry
    }

    private struct Arguments: Decodable { let task_id: String }

    public var toolName: String { "check_task" }
    public var toolDescription: String {
        "Get the current status and any produced result of a previously delegated task by its task_id "
            + "(from delegate_async). Returns the result text when the task has completed."
    }
    public var inputSchema: JSONSchema {
        .object(
            properties: ["task_id": .string(description: "The task_id returned by delegate_async.")],
            required: ["task_id"]
        )
    }

    public func execute(with argumentsData: Data) async throws -> ToolResult {
        let arguments = try JSONDecoder().decode(Arguments.self, from: argumentsData)
        let status = try await registry.checkTask(TaskID(arguments.task_id))
        switch status.state {
        case .failed:
            return .error("Task \(status.taskId.rawValue) (\(status.agentName)) failed: \(status.text)")
        case .canceled, .rejected:
            return .error("Task \(status.taskId.rawValue) (\(status.agentName)) did not complete (\(status.state.rawValue)): \(status.text)")
        case .inputRequired, .authRequired:
            let question = status.text.isEmpty ? "(no prompt provided)" : status.text
            return .text("Agent \(status.agentName) needs more input before it can continue. Ask the user: \(question)")
        case .completed:
            return .text(status.text.isEmpty ? "Agent \(status.agentName) completed with no text." : status.text)
        default:
            return .text("Task \(status.taskId.rawValue) (\(status.agentName)) is still \(status.state.rawValue). Check again later.")
        }
    }
}

/// 進行中（未完了）の委譲タスクを列挙するツール（A2A `tasks/get` で各タスクを refresh）。
public struct ListRunningTasksTool: Tool {
    private let registry: AgentConnectionRegistry

    public init(registry: AgentConnectionRegistry) {
        self.registry = registry
    }

    private struct RunningTask: Encodable {
        let agent_name: String
        let task_id: String
        let state: String
    }

    public var toolName: String { "list_running_tasks" }
    public var toolDescription: String {
        "List all delegated tasks that are still running (not yet completed). "
            + "Each entry has agent_name, task_id and state. Use check_task to fetch a completed task's result."
    }
    public var inputSchema: JSONSchema {
        .object(properties: [:])
    }

    public func execute(with argumentsData: Data) async throws -> ToolResult {
        let running = await registry.listRunningTasks()
        let payload = running.map { RunningTask(agent_name: $0.agentName, task_id: $0.taskId.rawValue, state: $0.state.rawValue) }
        let data = try JSONEncoder().encode(payload)
        return .json(data)
    }
}
