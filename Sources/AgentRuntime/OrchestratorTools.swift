import A2ACore
import LLMClient
import LLMTool
import Foundation

/// Lets the model read the roster of workers it can delegate to.
/// The host prompt names this tool literally, so renaming it breaks the prompt.
struct ListRemoteAgentsTool: Tool {
    private let registry: AgentConnectionRegistry

    init(registry: AgentConnectionRegistry) {
        self.registry = registry
    }

    var toolName: String { "list_remote_agents" }
    var toolDescription: String {
        "List the available remote agents you can use to delegate the task. Returns each agent's name and description."
    }
    var inputSchema: JSONSchema {
        .object(properties: [:])
    }

    func execute(with argumentsData: Data) async throws -> ToolResult {
        let agents = await registry.descriptors()
        let data = try JSONEncoder().encode(agents)
        return .json(data)
    }
}

/// Delegates to one worker and blocks until it finishes.
///
/// A worker that failed or was cancelled comes back as an error result, and one waiting on input
/// comes back as ordinary text telling the model to ask the user — so the loop continues either
/// way and the model gets a chance to react. Only a transport failure throws.
/// The host prompt names this tool literally.
struct SendMessageTool: Tool {
    private let registry: AgentConnectionRegistry

    init(registry: AgentConnectionRegistry) {
        self.registry = registry
    }

    private struct Arguments: Decodable {
        let agent_name: String
        let message: String
    }

    var toolName: String { "send_message" }
    var toolDescription: String {
        "Send a message to exactly ONE remote agent by name to take action, and get its response. "
            + "Include the agent name from list_remote_agents. Call this tool once per agent."
    }
    var inputSchema: JSONSchema {
        .object(
            properties: [
                "agent_name": .string(description: "The name of a single agent to send the task to (never a comma-separated list)."),
                "message": .string(description: "The message/instruction to send to the agent."),
            ],
            required: ["agent_name", "message"]
        )
    }

    func execute(with argumentsData: Data) async throws -> ToolResult {
        let arguments = try JSONDecoder().decode(Arguments.self, from: argumentsData)
        let outcome = try await registry.send(to: arguments.agent_name, text: arguments.message)

        switch outcome.state {
        case .failed:
            return .error("Agent \(outcome.name) failed: \(outcome.text)")
        case .canceled, .rejected:
            return .error("Agent \(outcome.name) did not complete (\(outcome.state?.rawValue ?? "")): \(outcome.text)")
        case .inputRequired, .authRequired:
            let question = outcome.text.isEmpty ? "(no prompt provided)" : outcome.text
            return .text("Agent \(outcome.name) needs more input before it can continue. "
                + "Ask the user: \(question)")
        default:
            if outcome.text.isEmpty {
                let stateLabel = outcome.state.map { $0.rawValue } ?? "ok"
                return .text("Agent \(outcome.name) responded (\(stateLabel)) with no text.")
            }
            return .text(outcome.text)
        }
    }
}

/// Starts a worker without waiting, returning a task id the model can follow up on.
///
/// This is how the model fans work out to several workers at once. The worker keeps running after
/// the host's turn ends, so the model may answer the user immediately and let completion arrive
/// later. A worker that finishes instantly returns its answer inline with no task id at all.
struct DelegateAsyncTool: Tool {
    private let registry: AgentConnectionRegistry

    init(registry: AgentConnectionRegistry) {
        self.registry = registry
    }

    private struct Arguments: Decodable {
        let agent_name: String
        let message: String
    }

    var toolName: String { "delegate_async" }
    var toolDescription: String {
        "Delegate a task to exactly ONE remote agent and return IMMEDIATELY with a task_id, "
            + "WITHOUT waiting for it to finish. Use this to start multiple agents working in parallel. "
            + "You do NOT have to wait for it within this turn — you may respond to the user now and the task "
            + "keeps running in the background; its completion is delivered automatically. "
            + "Use check_task to fetch a result on demand, or list_running_tasks to see what is still in flight."
    }
    var inputSchema: JSONSchema {
        .object(
            properties: [
                "agent_name": .string(description: "The name of a single agent to delegate to (from list_remote_agents)."),
                "message": .string(description: "The message/instruction to send to the agent."),
            ],
            required: ["agent_name", "message"]
        )
    }

    func execute(with argumentsData: Data) async throws -> ToolResult {
        let arguments = try JSONDecoder().decode(Arguments.self, from: argumentsData)
        let handle = try await registry.delegateAsync(to: arguments.agent_name, text: arguments.message)
        guard let taskId = handle.taskId else {
            // The worker answered outright without opening a task; there is nothing to poll.
            return .text(handle.immediateText.isEmpty
                ? "Agent \(handle.name) responded immediately with no text."
                : handle.immediateText)
        }
        let state = handle.state?.rawValue ?? "submitted"
        return .text("Started agent \(handle.name) in the background. "
            + "task_id=\(taskId.rawValue), state=\(state). "
            + "It keeps running; use check_task with this task_id to get its result, or list_running_tasks to see all in-flight tasks.")
    }
}

/// Reads a background task's state and result on demand.
///
/// Read-only and repeatable. A task still running comes back as text telling the model to check
/// again later, so a poll loop costs a model step each time it goes round.
struct CheckTaskTool: Tool {
    private let registry: AgentConnectionRegistry

    init(registry: AgentConnectionRegistry) {
        self.registry = registry
    }

    private struct Arguments: Decodable { let task_id: String }

    var toolName: String { "check_task" }
    var toolDescription: String {
        "Get the current status and any produced result of a previously delegated task by its task_id "
            + "(from delegate_async). Returns the result text when the task has completed."
    }
    var inputSchema: JSONSchema {
        .object(
            properties: ["task_id": .string(description: "The task_id returned by delegate_async.")],
            required: ["task_id"]
        )
    }

    func execute(with argumentsData: Data) async throws -> ToolResult {
        let arguments = try JSONDecoder().decode(Arguments.self, from: argumentsData)
        let status = try await registry.checkTask(TaskID(arguments.task_id))
        switch status.state {
        case .failed:
            return .error("Task \(status.taskId.rawValue) (\(status.name)) failed: \(status.text)")
        case .canceled, .rejected:
            return .error("Task \(status.taskId.rawValue) (\(status.name)) did not complete (\(status.state.rawValue)): \(status.text)")
        case .inputRequired, .authRequired:
            let question = status.text.isEmpty ? "(no prompt provided)" : status.text
            return .text("Agent \(status.name) needs more input before it can continue. Ask the user: \(question)")
        case .completed:
            return .text(status.text.isEmpty ? "Agent \(status.name) completed with no text." : status.text)
        default:
            return .text("Task \(status.taskId.rawValue) (\(status.name)) is still \(status.state.rawValue). Check again later.")
        }
    }
}

/// Lists the background tasks still in flight, re-reading each one.
/// Completed tasks are absent — their results are fetched by task id instead.
struct ListRunningTasksTool: Tool {
    private let registry: AgentConnectionRegistry

    init(registry: AgentConnectionRegistry) {
        self.registry = registry
    }

    private struct RunningTask: Encodable {
        let agent_name: String
        let task_id: String
        let state: String
    }

    var toolName: String { "list_running_tasks" }
    var toolDescription: String {
        "List all delegated tasks that are still running (not yet completed). "
            + "Each entry has agent_name, task_id and state. Use check_task to fetch a completed task's result."
    }
    var inputSchema: JSONSchema {
        .object(properties: [:])
    }

    func execute(with argumentsData: Data) async throws -> ToolResult {
        let running = await registry.listRunningTasks()
        let payload = running.map { RunningTask(agent_name: $0.name, task_id: $0.taskId.rawValue, state: $0.state.rawValue) }
        let data = try JSONEncoder().encode(payload)
        return .json(data)
    }
}
