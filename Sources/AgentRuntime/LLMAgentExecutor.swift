import AgentLoopKit
import A2ACore
import A2AServer
import LLMClient
import LLMTool

/// `AgentLoop` を A2A の `AgentExecutor` として実行するワーカー（a2a-samples の agent_executor 相当）。
public struct LLMAgentExecutor<Client: AgentCapableClient>: AgentExecutor where Client.Model: Sendable {
    private let client: Client
    private let model: Client.Model
    private let tools: ToolSet
    private let systemPrompt: SystemPrompt?
    private let maxSteps: Int
    private let artifactName: String
    private let maxTokens: Int?

    public init(
        client: Client,
        model: Client.Model,
        tools: ToolSet = ToolSet {},
        systemPrompt: SystemPrompt? = nil,
        maxSteps: Int = 12,
        artifactName: String = "response",
        maxTokens: Int? = nil
    ) {
        self.client = client
        self.model = model
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.maxSteps = maxSteps
        self.artifactName = artifactName
        self.maxTokens = maxTokens
    }

    public func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()

        let loop = AgentLoop(
            client: client,
            model: model,
            tools: tools,
            systemPrompt: systemPrompt,
            maxSteps: maxSteps,
            maxTokens: maxTokens
        )

        // ワーカーが消費したトークンを集約し、完了時に artifact metadata で呼び出し元へ返す。
        var totalUsage: TokenUsage?
        do {
            try await loop.run(messages: reconstructMessages(from: context)) { event in
                switch event {
                case .thinking(let text):
                    if !text.isEmpty {
                        try await updater.updateStatus(.working, message: updater.newAgentMessage([.text(text)]))
                    }
                case .toolCall(_, let name):
                    try await updater.updateStatus(.working, message: updater.newAgentMessage([.text("🔧 \(name)")]))
                case .toolResult:
                    break
                case .usage(let usage, _):
                    totalUsage = totalUsage?.adding(usage) ?? usage
                case .inputRequired(let question):
                    try await updater.requiresInput(message: updater.newAgentMessage([.text(question)]))
                case .completed(let text):
                    await updater.addArtifact([.text(text)], name: artifactName, metadata: totalUsage.flatMap(UsageMetadata.encode))
                    try await updater.complete()
                case .validationFailed:
                    // ワーカー（単一 AgentLoop）は検証フックを持たないため発火しない（網羅性のための no-op）。
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? await updater.failed(message: updater.newAgentMessage([.text("\(error)")]))
        }
    }

    public func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.cancel()
    }

    // resume（同一タスクへの再送）で文脈を引き継ぐため、A2A タスク履歴を LLM 会話へ復元する。
    private func reconstructMessages(from context: RequestContext) -> [LLMMessage] {
        var messages: [LLMMessage] = []
        for historical in context.currentTask?.history ?? [] {
            let text = historical.parts.compactMap(\.text).joined()
            guard !text.isEmpty else { continue }
            messages.append(historical.role == .agent ? .assistant(text) : .user(text))
        }
        messages.append(.user(context.getUserInput()))
        return messages
    }
}
