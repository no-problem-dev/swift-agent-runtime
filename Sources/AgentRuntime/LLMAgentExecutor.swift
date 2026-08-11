import AgentLoopKit
import A2ACore
import A2AServer
import LLMClient
import LLMTool
import LLMAgentStep

/// Wraps a single LLM agent as an A2A worker, driving the task lifecycle for it.
///
/// The turn is reported as it goes: working while the model runs, a status update naming each
/// tool it calls, an artifact carrying the final text, and then completion. A turn that throws is
/// reported as a failed task rather than propagated, so the error reaches the caller as text and
/// this method still returns normally.
///
/// A tool that needs approval dead-ends here: the request is reported as a question to the user,
/// but nothing on this path can carry a verdict back, so resending will ask again.
public struct LLMAgentExecutor<Client: AgentCapableClient>: AgentExecutor where Client.Model: Sendable {
    private let client: Client
    private let model: Client.Model
    private let tools: ToolSet
    private let systemPrompt: SystemPrompt?
    private let maxSteps: Int
    private let artifactName: String
    private let maxTokens: Int?
    private let cachePolicy: PromptCachePolicy
    private let onSystemPrompt: (@Sendable (String) async -> Void)?
    private let historyStore: (any AgentHistoryStore)?

    /// Creates a worker bound to one client, model and tool set.
    ///
    /// - Parameters:
    ///   - client: The LLM client every turn runs on.
    ///   - model: The model identifier.
    ///   - tools: Tools the model may call. Empty by default.
    ///   - systemPrompt: Prepended to every step. When `nil`, only the date line is sent.
    ///   - maxSteps: Step budget per turn. Exhausting it completes the task with empty text
    ///     rather than failing it, so an empty artifact is not proof of an empty answer.
    ///   - artifactName: The name given to the artifact carrying the final text.
    ///   - maxTokens: Output token ceiling per step. `nil` uses the model's default.
    ///   - cachePolicy: Prompt caching for the stable prefix.
    ///   - onSystemPrompt: Receives the fully assembled prompt, tool-supplied instructions
    ///     included, once per turn. For debugging. `nil` observes nothing.
    ///   - historyStore: Where the conversation lives. With a store, follow-ups continue from the
    ///     native transcript, tool calls and results intact. Without one, the conversation is
    ///     rebuilt from the task history as flat text, which turns past tool calls into assistant
    ///     prose and teaches the model to answer that way instead of calling tools.
    public init(
        client: Client,
        model: Client.Model,
        tools: ToolSet = ToolSet {},
        systemPrompt: SystemPrompt? = nil,
        maxSteps: Int = 12,
        artifactName: String = "response",
        maxTokens: Int? = nil,
        cachePolicy: PromptCachePolicy = .implicit,
        onSystemPrompt: (@Sendable (String) async -> Void)? = nil,
        historyStore: (any AgentHistoryStore)? = nil
    ) {
        self.client = client
        self.model = model
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.maxSteps = maxSteps
        self.artifactName = artifactName
        self.maxTokens = maxTokens
        self.cachePolicy = cachePolicy
        self.onSystemPrompt = onSystemPrompt
        self.historyStore = historyStore
    }

    public func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()

        // Tokens are summed across the turn and attached to the final artifact, which is how the
        // caller learns what this worker cost — A2A has no event for it.
        let usage = UsageAccumulator()
        let onSystemPrompt = self.onSystemPrompt
        let loop = AgentLoop(
            client: client,
            model: model,
            tools: tools,
            systemPrompt: systemPrompt,
            maxSteps: maxSteps,
            maxTokens: maxTokens,
            cachePolicy: cachePolicy,
            telemetry: { telemetry in
                switch telemetry {
                case .usage(let u, _): await usage.add(u)
                case .systemPrompt(let rendered): await onSystemPrompt?(rendered)
                case .validationFailed: break
                }
            }
        )

        let messages = try await makeMessages(from: context)
        do {
            // Deltas are buffered and posted as one status update when a tool call comes along:
            // a status update per chunk is noise on the A2A wire. Bounded by the step's own text,
            // and discarded if the turn ends without a tool call.
            var stepText = ""
            let transcript = try await loop.run(messages: messages) { event in
                switch event {
                case .textDelta(let delta):
                    stepText += delta
                case .toolCall(_, let name, _):
                    if !stepText.isEmpty {
                        try await updater.updateStatus(.working, message: updater.makeAgentMessage([.text(stepText)]))
                        stepText = ""
                    }
                    try await updater.updateStatus(.working, message: updater.makeAgentMessage([.text("🔧 \(name)")]))
                case .toolResult, .thinkingDelta:
                    break
                case .toolApprovalRequired(_, _, _, let request):
                    // Reported as a question to the user, since A2A has no approval vocabulary.
                    // The answer comes back as plain text, which cannot resume the held tool call.
                    try await updater.requiresInput(message: updater.makeAgentMessage([.text(request.summary)]))
                case .inputRequired(let question):
                    try await updater.requiresInput(message: updater.makeAgentMessage([.text(question)]))
                case .completed(let text):
                    let total = await usage.total
                    await updater.addArtifact([.text(text)], name: artifactName, metadata: total.flatMap(UsageMetadata.encode))
                    try await updater.complete()
                }
            }
            await historyStore?.save(transcript, for: context.contextId.rawValue)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? await updater.fail(message: updater.makeAgentMessage([.text("\(error)")]))
        }
    }

    public func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.cancel()
    }

    /// Assembles the conversation: the stored native history when there is a store, otherwise a
    /// text-only reconstruction from the task history.
    private func makeMessages(from context: RequestContext) async throws -> [LLMMessage] {
        if let historyStore {
            let history = await historyStore.history(for: context.contextId.rawValue)
            return history + [try userMessage(from: context)]
        }
        return try reconstructMessages(from: context)
    }

    /// Converts the incoming parts into a user message, carrying attachments through.
    /// An empty request becomes an empty message rather than an error.
    private func userMessage(from context: RequestContext) throws -> LLMMessage {
        guard let parts = context.message?.parts, !parts.isEmpty else { return .user("") }
        return try MultimodalInput.userMessage(from: parts)
    }

    // Fallback used when no history store is configured: rebuild the conversation from the task
    // history so a resend keeps its context. Everything becomes flat text — past tool calls and
    // their results are lost, and attachments in earlier turns do not survive.
    private func reconstructMessages(from context: RequestContext) throws -> [LLMMessage] {
        var messages: [LLMMessage] = []
        for historical in context.currentTask?.history ?? [] {
            let text = historical.parts.compactMap(\.text).joined()
            guard !text.isEmpty else { continue }
            messages.append(historical.role == .agent ? .assistant(text) : .user(text))
        }
        messages.append(try userMessage(from: context))
        return messages
    }
}
