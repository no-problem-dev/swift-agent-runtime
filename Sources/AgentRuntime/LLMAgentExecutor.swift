import AgentLoopKit
import A2ACore
import A2AServer
import LLMClient
import LLMTool

/// ランタイム自前の `AgentLoop` を A2A の `AgentExecutor` として実行するアダプタ（ワーカー）。
/// a2a-samples の各 `agent_executor.py` に相当。
///
/// ループの `AgentLoop.Event` を `TaskUpdater` 経由で A2A イベントへ写像する:
/// - `.thinking` / `.toolCall` → `TaskState.working`（進捗）
/// - `.inputRequired`         → `TaskState.inputRequired`（中断、resume 待ち）
/// - `.completed`             → artifact 追加 + `TaskState.completed`
///
/// swift-llm-agent には依存せず、swift-llm-client の `AgentCapableClient` + `ToolSet` のみを使う。
/// 任意のプロバイダ（OpenAI 等）と MCP ツールをそのまま注入できる。
public struct LLMAgentExecutor<Client: AgentCapableClient>: AgentExecutor where Client.Model: Sendable {
    private let client: Client
    private let model: Client.Model
    private let tools: ToolSet
    private let systemPrompt: SystemPrompt?
    private let maxSteps: Int
    private let artifactName: String

    public init(
        client: Client,
        model: Client.Model,
        tools: ToolSet = ToolSet {},
        systemPrompt: SystemPrompt? = nil,
        maxSteps: Int = 12,
        artifactName: String = "response"
    ) {
        self.client = client
        self.model = model
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.maxSteps = maxSteps
        self.artifactName = artifactName
    }

    public func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()

        let loop = AgentLoop(
            client: client,
            model: model,
            tools: tools,
            systemPrompt: systemPrompt,
            maxSteps: maxSteps
        )
        let messages = reconstructMessages(from: context)

        do {
            // 構造化: ループは execute のタスク内で走る。execute は DefaultRequestHandler の
            // producer 子タスクなので、キャンセルはツリーを通じてここまで伝播する。
            try await loop.run(messages: messages) { event in
                switch event {
                case .thinking(let text):
                    if !text.isEmpty {
                        try await updater.updateStatus(.working, message: updater.newAgentMessage([.text(text)]))
                    }
                case .toolCall(_, let name):
                    try await updater.updateStatus(.working, message: updater.newAgentMessage([.text("🔧 \(name)")]))
                case .toolResult:
                    break
                case .inputRequired(let question):
                    try await updater.requiresInput(message: updater.newAgentMessage([.text(question)]))
                case .completed(let text):
                    await updater.addArtifact([.text(text)], name: artifactName)
                    try await updater.complete()
                }
            }
        } catch is CancellationError {
            // キャンセルは正常（DefaultRequestHandler が canceled へ遷移させる）。
            throw CancellationError()
        } catch {
            try? await updater.failed(message: updater.newAgentMessage([.text("\(error)")]))
        }
    }

    public func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.cancel()
    }

    /// A2A タスク履歴（input-required 時の質問など）を LLM 会話へ復元し、新しいユーザー入力を末尾に足す。
    /// これにより resume（同一タスクへの再送）でワーカーが文脈を引き継げる。
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
