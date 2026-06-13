import AgentLoopKit
import A2ACore
import A2AServer
import LLMClient
import LLMTool
import LLMAgentStep

/// `AgentLoop` を A2A の `AgentExecutor` として実行するワーカー（a2a-samples の agent_executor 相当）。
public struct LLMAgentExecutor<Client: AgentCapableClient>: AgentExecutor where Client.Model: Sendable {
    private let client: Client
    private let model: Client.Model
    private let tools: ToolSet
    private let systemPrompt: SystemPrompt?
    private let maxSteps: Int
    private let artifactName: String
    private let maxTokens: Int?
    private let cachePolicy: PromptCachePolicy
    /// ループが実際にレンダリングした system prompt（ツール同伴指示込み）の観測フック。
    /// 計測（デバッグレコーダ等）向け。nil = 観測しない。
    private let onSystemPrompt: (@Sendable (String) async -> Void)?
    /// LLM 会話履歴ストア。指定時はネイティブ transcript（tool call/result 込み）で
    /// マルチターンを継続し、A2A タスク履歴からのテキスト復元を行わない。
    private let historyStore: (any AgentHistoryStore)?

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

        // ワーカーが消費したトークンを集約し、完了時に artifact metadata で呼び出し元へ返す。
        // usage（metrics）と systemPrompt（debug）は意味論イベントと別の telemetry 側帯で受ける。
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

        let messages = await makeMessages(from: context)
        do {
            let transcript = try await loop.run(messages: messages) { event in
                switch event {
                case .thinking(let text):
                    if !text.isEmpty {
                        try await updater.updateStatus(.working, message: updater.newAgentMessage([.text(text)]))
                    }
                case .toolCall(_, let name, _):
                    try await updater.updateStatus(.working, message: updater.newAgentMessage([.text("🔧 \(name)")]))
                case .toolResult:
                    break
                case .inputRequired(let question):
                    try await updater.requiresInput(message: updater.newAgentMessage([.text(question)]))
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
            try? await updater.failed(message: updater.newAgentMessage([.text("\(error)")]))
        }
    }

    public func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.cancel()
    }

    /// historyStore があればネイティブ履歴 + 新規入力、なければ A2A タスク履歴からの復元。
    private func makeMessages(from context: RequestContext) async -> [LLMMessage] {
        if let historyStore {
            let history = await historyStore.history(for: context.contextId.rawValue)
            return history + [.user(context.getUserInput())]
        }
        return reconstructMessages(from: context)
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
