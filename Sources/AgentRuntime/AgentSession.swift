import AgentLoopKit
import A2ACore
import LLMClient
import LLMTool
import Foundation

/// オーケストレータ（ホスト）のセッション。a2a-samples `HostAgent` 相当。
///
/// ホスト自身がランタイム自前の `AgentLoop` で動く LLM エージェントであり、`list_agents` /
/// `send_message` ツールで登録済みワーカーへ委譲する。各ワーカーは `AgentConnectionRegistry`
/// を通じて A2A（in-process / remote）越しに、それぞれ別 Task で実行される。
///
/// `run` / `stream` を跨いで **ホスト自身の会話履歴を保持**する（マルチターン）。
/// ワーカー側のタスク継続（input-required の resume 等）は `AgentConnectionRegistry` が担う。
///
/// swift-llm-agent には依存せず、swift-llm-client の `AgentCapableClient` + `ToolSet` のみを使う。
public actor AgentSession<Client: AgentCapableClient> where Client.Model: Sendable {
    private let client: Client
    private let model: Client.Model
    private let registry: AgentConnectionRegistry
    private let extraTools: ToolSet
    private let instruction: String
    private let maxSteps: Int

    /// ホスト自身の会話履歴（user / assistant のターン）。
    private var history: [LLMMessage] = []

    /// 進行中の run タスク（セッションがライフサイクル所有者として保持し、cancel() で止める）。
    private var currentRun: Task<String, Error>?

    /// 既定の委譲インストラクション（`HostAgent.root_instruction` 相当）。
    public static var defaultInstruction: String {
        """
        You are an expert delegator. Delegate the user's request to the most appropriate \
        remote agent(s) using the `send_message` tool, then synthesize their responses into \
        a final answer for the user. Use `list_agents` to discover who is available. \
        Always mention which agent produced each result, and rely on tools rather than \
        making up answers.
        """
    }

    public init(
        client: Client,
        model: Client.Model,
        registry: AgentConnectionRegistry,
        extraTools: ToolSet = ToolSet {},
        instruction: String? = nil,
        maxSteps: Int = 12
    ) {
        self.client = client
        self.model = model
        self.registry = registry
        self.extraTools = extraTools
        self.instruction = instruction ?? Self.defaultInstruction
        self.maxSteps = maxSteps
    }

    /// 蓄積されたホスト会話履歴。
    public var messages: [LLMMessage] { history }

    /// 会話履歴をクリアする。
    public func clear() {
        history.removeAll()
    }

    /// ユーザー入力を処理し、オーケストレータの最終テキストを返す。履歴を継続する。
    ///
    /// 実行はセッションが保持する `currentRun` タスク内で走る。`cancel()` でこのタスクを
    /// キャンセルすると、構造化ツリーを通じて委譲先ワーカーまで伝播する。
    public func run(_ userInput: String) async throws -> String {
        let task = Task { try await self.runInner(userInput) }
        currentRun = task
        defer { currentRun = nil }
        // 呼び出し元タスクのキャンセルを保持タスクへ橋渡しする。これにより
        // 「外部 Task のキャンセル（構造化）」と「cancel() API」の双方が同じ経路で効く。
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 進行中の run をキャンセルし、委譲中のワーカーも A2A `cancelTask` で停止する。
    ///
    /// 二層で止める: (1) `currentRun` のキャンセルが構造化ツリーをワーカーまで伝播し、
    /// (2) `registry.cancelAll()` が A2A `cancelTask` で各ワーカーのタスクを終端化する。
    public func cancel() async {
        currentRun?.cancel()
        await registry.cancelAll()
    }

    private func runInner(_ userInput: String) async throws -> String {
        let loop = await makeLoop()
        var finalText = ""
        try await loop.run(messages: history + [.user(userInput)]) { event in
            if case .completed(let text) = event {
                finalText = text
            }
        }
        history.append(.user(userInput))
        history.append(.assistant(finalText))
        return finalText
    }

    /// オーケストレータのループイベントをストリームで返す。完了時に履歴を継続する。
    /// ストリーム返却の境界としてのみ Task を立て、ループ本体は構造化のまま走らせる。
    public func stream(_ userInput: String) -> AsyncThrowingStream<AgentLoop<Client>.Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let loop = await self.makeLoop()
                    let prior = self.history
                    var finalText = ""
                    try await loop.run(messages: prior + [.user(userInput)]) { event in
                        if case .completed(let text) = event { finalText = text }
                        continuation.yield(event)
                    }
                    self.appendTurn(user: userInput, assistant: finalText)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func appendTurn(user: String, assistant: String) {
        history.append(.user(user))
        history.append(.assistant(assistant))
    }

    private func makeLoop() async -> AgentLoop<Client> {
        AgentLoop(
            client: client,
            model: model,
            tools: makeTools(),
            systemPrompt: await makeSystemPrompt(),
            maxSteps: maxSteps
        )
    }

    private func makeTools() -> ToolSet {
        extraTools + ToolSet {
            ListAgentsTool(registry: registry)
            SendMessageTool(registry: registry)
        }
    }

    private func makeSystemPrompt() async -> SystemPrompt {
        let descriptors = await registry.descriptors()
        let list = descriptors.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let text = list.isEmpty ? instruction : "\(instruction)\n\nAvailable agents:\n\(list)"
        return SystemPrompt(stringLiteral: text)
    }
}
