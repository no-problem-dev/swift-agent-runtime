import AgentLoopKit
import A2ACore
import LLMClient
import LLMTool
import Foundation

/// オーケストレータ（ホスト）のセッション（a2a-samples `HostAgent` 相当）。
///
/// ホスト自身が `AgentLoop` で動く LLM エージェントで、`list_agents` / `send_message` で
/// 登録済みワーカーへ委譲する。`run` / `stream` を跨いでホストの会話履歴を保持する。
public actor AgentSession<Client: AgentCapableClient> where Client.Model: Sendable {
    private let client: Client
    private let model: Client.Model
    private let registry: AgentConnectionRegistry
    private let extraTools: ToolSet
    private let instruction: String
    private let maxSteps: Int
    private var history: [LLMMessage] = []
    private var currentRun: Task<String, Error>?

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

    public var messages: [LLMMessage] { history }

    public func clear() {
        history.removeAll()
    }

    public func run(_ userInput: String) async throws -> String {
        let task = Task { try await self.runInner(userInput) }
        currentRun = task
        defer { currentRun = nil }
        // 呼び出し元タスクのキャンセルを保持タスクへ橋渡しし、構造化キャンセルと cancel() を同経路にする。
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 進行中 run を止め（構造化ツリーで委譲先まで伝播）、ワーカーも A2A `cancelTask` で終端化する。
    public func cancel() async {
        currentRun?.cancel()
        await registry.cancelAll()
    }

    private func runInner(_ userInput: String) async throws -> String {
        let loop = await makeLoop()
        var finalText = ""
        // 全トランスクリプト（委譲のツール呼び出し・結果含む）を履歴として保持。
        // → 次ターンで「さっき何を調べた？」等にツール無しで文脈から答えられる。
        history = try await loop.run(messages: history + [.user(userInput)]) { event in
            if case .completed(let text) = event {
                finalText = text
            }
        }
        return finalText
    }

    public func stream(_ userInput: String) -> AsyncThrowingStream<AgentLoop<Client>.Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let loop = await self.makeLoop()
                    let prior = self.history
                    let transcript = try await loop.run(messages: prior + [.user(userInput)]) { event in
                        continuation.yield(event)
                    }
                    self.setHistory(transcript)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func setHistory(_ messages: [LLMMessage]) {
        history = messages
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
