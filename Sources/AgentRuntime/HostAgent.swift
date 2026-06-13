import AgentLoopKit
import A2ACore
import LLMClient
import LLMTool
import LLMAgentStep
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
    /// 最終出力の検証フック。空配列＝有効、非空＝問題点（人間可読）を返す。`nil` なら検証しない（従来挙動）。
    /// A2UI 等のドメイン固有検証はここに注入することで、runtime をドメイン非依存に保つ。
    private let outputValidator: (@Sendable (String) -> [String])?
    /// 検証失敗時に LLM へ送る是正再プロンプトの組み立て。`(問題点, 元入力) -> 再プロンプト文`。
    private let correctivePrompt: (@Sendable (_ issues: [String], _ originalInput: String) -> String)?
    /// 検証失敗時の最大リトライ回数（初回生成は含まない。例: 1 なら計2試行）。
    private let maxValidationRetries: Int
    /// 安定プレフィックス（system prompt + tools）のキャッシュ方針。ループの全ステップに適用される。
    private let cachePolicy: PromptCachePolicy
    private var history: [LLMMessage] = []
    private var currentRun: Task<String, Error>?

    public init(
        client: Client,
        model: Client.Model,
        registry: AgentConnectionRegistry,
        outputInstruction: String? = nil,
        extraTools: ToolSet = ToolSet {},
        maxSteps: Int = 12,
        maxTokens: Int? = nil,
        outputValidator: (@Sendable (String) -> [String])? = nil,
        correctivePrompt: (@Sendable (_ issues: [String], _ originalInput: String) -> String)? = nil,
        maxValidationRetries: Int = 0,
        cachePolicy: PromptCachePolicy = .implicit
    ) {
        self.client = client
        self.model = model
        self.registry = registry
        self.outputInstruction = outputInstruction
        self.extraTools = extraTools
        self.maxSteps = maxSteps
        self.maxTokens = maxTokens
        self.outputValidator = outputValidator
        self.correctivePrompt = correctivePrompt
        self.maxValidationRetries = maxValidationRetries
        self.cachePolicy = cachePolicy
    }

    public var messages: [LLMMessage] { history }

    public func clear() {
        history.removeAll()
    }

    /// 復元（`session/load`）時に会話履歴を seed する。以後の run/stream はこの文脈を継続する。
    public func loadHistory(_ messages: [LLMMessage]) {
        history = messages
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

    /// セッション終了処理。明示キャッシュをサーバー側リソースとして所有するクライアントなら解放する
    /// （Gemini ではストレージ課金の停止）。それ以外のクライアントでは何もしない。
    public func close() async {
        if let releasing = client as? PromptCacheReleasing {
            await releasing.releasePromptCaches()
        }
    }

    private func runInner(_ userInput: String) async throws -> String {
        // 全トランスクリプト（委譲のツール呼び出し・結果含む）を履歴として保持。
        // → 次ターンで「さっき何を調べた？」等にツール無しで文脈から答えられる。
        // 検証フックがあれば、無効出力を是正再プロンプトで再生成する（prompt→generate→validate）。
        var input = userInput
        var attempt = 0
        var finalText = ""
        while true {
            let loop = await makeLoop()
            history = try await loop.run(messages: history + [.user(input)]) { event in
                if case .completed(let text) = event { finalText = text }
            }
            guard let validator = outputValidator else { return finalText }
            let issues = validator(finalText)
            if issues.isEmpty || attempt >= maxValidationRetries { return finalText }
            attempt += 1
            input = (correctivePrompt ?? Self.defaultCorrectivePrompt)(issues, userInput)
        }
    }

    public func stream(_ userInput: String, telemetry: AgentTelemetrySink? = nil) -> AsyncThrowingStream<AgentLoop<Client>.Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 検証フックがあれば、各生成後に検証し、無効なら是正再プロンプトを「新しいユーザーターン」
                    // として送り直して再生成する（会話履歴は保持される）。検証失敗は `telemetry` の
                    // `.validationFailed` で観測側へ流し、「再描画 or フォールバック」を判断できるようにする。
                    var input = userInput
                    var attempt = 0
                    while true {
                        let loop = await self.makeLoop(telemetry: telemetry)
                        let prior = self.history
                        var finalText = ""
                        let transcript = try await loop.run(messages: prior + [.user(input)]) { event in
                            if case .completed(let text) = event { finalText = text }
                            continuation.yield(event)
                        }
                        self.setHistory(transcript)

                        guard let validator = self.outputValidator else { break }
                        let issues = validator(finalText)
                        if issues.isEmpty { break }
                        let willRetry = attempt < self.maxValidationRetries
                        await telemetry?(.validationFailed(issues: issues, willRetry: willRetry))
                        if !willRetry { break }
                        attempt += 1
                        let builder = self.correctivePrompt ?? Self.defaultCorrectivePrompt
                        input = builder(issues, userInput)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 是正再プロンプトの汎用フォールバック（ドメイン固有のタグ等が要る場合は init で `correctivePrompt` を注入）。
    private static func defaultCorrectivePrompt(_ issues: [String], _ originalInput: String) -> String {
        "Your previous response was invalid: \(issues.joined(separator: "; ")). "
        + "Generate a corrected response that fixes these issues. "
        + "Original request: \(originalInput)"
    }

    private func setHistory(_ messages: [LLMMessage]) {
        history = messages
    }

    private func makeLoop(telemetry: AgentTelemetrySink? = nil) async -> AgentLoop<Client> {
        // 委譲先（リモートエージェント）が 1 件も登録されていなければ、委譲ツールも
        // delegator プロンプトも注入しない（単独実行）。空フリートで委譲語彙を残すと、
        // 特に小型オンデバイスモデルが存在しない委譲ツールを反射的に呼ぼうとして
        // ツール選択・出力品質が劣化するため。
        let roster = await registry.rosterJSONLines()
        let active = await registry.activeAgent
        let hasAgents = !roster.isEmpty
        return AgentLoop(
            client: client,
            model: model,
            tools: makeTools(includeDelegation: hasAgents),
            systemPrompt: makeSystemPrompt(agents: roster, activeAgent: active, hasAgents: hasAgents),
            maxSteps: maxSteps,
            maxTokens: maxTokens,
            cachePolicy: cachePolicy,
            telemetry: telemetry
        )
    }

    private func makeTools(includeDelegation: Bool) -> ToolSet {
        guard includeDelegation else { return extraTools }
        return extraTools + ToolSet {
            ListRemoteAgentsTool(registry: registry)
            SendMessageTool(registry: registry)
            DelegateAsyncTool(registry: registry)
            CheckTaskTool(registry: registry)
            ListRunningTasksTool(registry: registry)
        }
    }

    private func makeSystemPrompt(agents: String, activeAgent: String, hasAgents: Bool) -> SystemPrompt {
        let base = hasAgents
            ? HostInstruction.root(agents: agents, activeAgent: activeAgent)
            : HostInstruction.solo()
        let text = outputInstruction.map { "\(base)\n\n\($0)" } ?? base
        return SystemPrompt(stringLiteral: text)
    }
}
