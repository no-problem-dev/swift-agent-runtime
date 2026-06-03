import AgentLoopKit
import A2ACore
import LLMClient
import LLMTool
import Foundation

/// オーケストレータ（ホスト）エージェント（a2a-samples `HostAgent` 相当）。
///
/// ホスト自身が `AgentLoop` で動く LLM エージェントで、`list_remote_agents` / `send_message` で
/// 登録済みワーカーへ委譲する。system prompt は `HostInstruction.root`（公式 root_instruction の逐語移植）に
/// レジストリのロスターと現在エージェントを注入して組み立てる。委譲の reasoning 部分は一切カスタムせず、
/// アプリ固有の出力フォーマット指示だけを `outputInstruction` として後置する。
/// `run` / `stream` を跨いでホストの会話履歴を保持する。
public actor HostAgent<Client: AgentCapableClient> where Client.Model: Sendable {
    private let client: Client
    private let model: Client.Model
    private let registry: AgentConnectionRegistry
    private let extraTools: ToolSet
    /// 出力フォーマット等のアプリ固有指示。delegation 本文の後ろに別セクションとして付く（本文は不変）。
    private let outputInstruction: String?
    private let maxSteps: Int
    private let maxTokens: Int?
    private var history: [LLMMessage] = []
    private var currentRun: Task<String, Error>?

    public init(
        client: Client,
        model: Client.Model,
        registry: AgentConnectionRegistry,
        outputInstruction: String? = nil,
        extraTools: ToolSet = ToolSet {},
        maxSteps: Int = 12,
        maxTokens: Int? = nil
    ) {
        self.client = client
        self.model = model
        self.registry = registry
        self.outputInstruction = outputInstruction
        self.extraTools = extraTools
        self.maxSteps = maxSteps
        self.maxTokens = maxTokens
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
            maxSteps: maxSteps,
            maxTokens: maxTokens
        )
    }

    private func makeTools() -> ToolSet {
        extraTools + ToolSet {
            ListRemoteAgentsTool(registry: registry)
            SendMessageTool(registry: registry)
        }
    }

    private func makeSystemPrompt() async -> SystemPrompt {
        let agents = await registry.rosterJSONLines()
        let active = await registry.activeAgent
        let root = HostInstruction.root(agents: agents, activeAgent: active)
        let text = outputInstruction.map { "\(root)\n\n\($0)" } ?? root
        return SystemPrompt(stringLiteral: text)
    }
}
