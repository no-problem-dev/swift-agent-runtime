import AgentLoopKit
import A2ACore
import LLMClient
import LLMTool
import LLMAgentStep
import Foundation

/// ルーター型ホスト（公式 A2UI orchestrator サンプル `samples/agent/adk/orchestrator` 相当）。
///
/// `HostAgent`（委譲ループ型: ワーカー結果を集約し自分で最終出力を合成する）と異なり、
/// 責務はルーティングのみ。受信メッセージを 1 回の推論 — または `hooks.preRoute` による
/// 決定的判定 — でちょうど 1 ワーカーへ転送し、ワーカーの応答イベントを**再合成せず
/// パススルー**する。UI カタログ等のドメイン知識は一切持たないため、system prompt は
/// 公式逐語のルーティング 1 文 + ロスターだけで済む。
///
/// A2UI 連携は `Hooks` として注入する（公式サンプルとの対応）:
/// - `preRoute` ← `before_model_callback`（userAction の surfaceId ルーティング）
/// - `prepareOutbound` ← `A2UIMetadataInterceptor`（capabilities 注入 + data model ストリッピング）
/// - `observeWorkerParts` ← `agent_executor` のイベント観測（surface 所有の記録）
public actor RouterHostAgent<Client: AgentCapableClient> where Client.Model: Sendable {

    public struct Hooks: Sendable {
        /// LLM を介さない決定的ルーティング。受信パーツから転送先ワーカー名を返す。
        /// `nil` = LLM ルーティングへフォールバック（公式の `return None` と同じ意味論）。
        public var preRoute: @Sendable ([Part]) async -> String?
        /// 転送直前の message metadata 変換。
        public var prepareOutbound: @Sendable (A2AMetadata?, _ target: String) async throws -> A2AMetadata?
        /// ワーカー応答パーツの観測。`agent` はワーカー名（公式の `event.author`）。
        public var observeWorkerParts: @Sendable ([Part], _ agent: String) async -> Void

        public init(
            preRoute: @escaping @Sendable ([Part]) async -> String? = { _ in nil },
            prepareOutbound: @escaping @Sendable (A2AMetadata?, String) async throws -> A2AMetadata? = { metadata, _ in metadata },
            observeWorkerParts: @escaping @Sendable ([Part], String) async -> Void = { _, _ in }
        ) {
            self.preRoute = preRoute
            self.prepareOutbound = prepareOutbound
            self.observeWorkerParts = observeWorkerParts
        }
    }

    public enum Event: Sendable {
        /// ルーティング決定。`deterministic` = LLM を介さず決定（userAction ルート等）。
        case routed(agent: String, deterministic: Bool, usage: TokenUsage?)
        /// ワーカーからのパススルーイベント。
        case worker(StreamResponse)
    }

    private let client: Client
    private let model: Client.Model
    private let registry: AgentConnectionRegistry
    private let hooks: Hooks
    private let maxTokens: Int?
    private let cachePolicy: PromptCachePolicy
    private var history: [LLMMessage] = []

    public init(
        client: Client,
        model: Client.Model,
        registry: AgentConnectionRegistry,
        hooks: Hooks = Hooks(),
        maxTokens: Int? = nil,
        cachePolicy: PromptCachePolicy = .implicit
    ) {
        self.client = client
        self.model = model
        self.registry = registry
        self.hooks = hooks
        self.maxTokens = maxTokens
        self.cachePolicy = cachePolicy
    }

    /// 現在のルーティング会話履歴（ユーザー入力とワーカー応答の要約を含む）。
    public var messages: [LLMMessage] { history }

    /// ルーティング会話履歴をリセットする。次の `send` は新規セッションとして開始する。
    public func clear() {
        history.removeAll()
    }

    /// 進行中の委譲タスクをキャンセルする。
    public func cancel() async {
        await registry.cancelAll()
    }

    /// セッション終了処理。明示プロンプトキャッシュを保持するクライアントのキャッシュを解放する。
    public func close() async {
        if let releasing = client as? PromptCacheReleasing {
            await releasing.releasePromptCaches()
        }
    }

    /// メッセージをちょうど 1 ワーカーへ転送し、応答イベントをパススルーで流す。
    public func send(_ parts: [Part], metadata: A2AMetadata? = nil) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.route(parts, metadata: metadata) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func route(
        _ parts: [Part],
        metadata: A2AMetadata?,
        yield: @Sendable (Event) -> Void
    ) async throws {
        let target: String
        let deterministic: Bool
        var routingUsage: TokenUsage?

        if let preRouted = await hooks.preRoute(parts) {
            target = preRouted
            deterministic = true
        } else {
            let decision = try await decideRoute(for: parts)
            target = decision.agent
            deterministic = false
            routingUsage = decision.usage
        }
        yield(.routed(agent: target, deterministic: deterministic, usage: routingUsage))

        let outbound = try await hooks.prepareOutbound(metadata, target)
        let stream = try await registry.stream(to: target, parts: parts, metadata: outbound)

        var workerTexts: [String] = []
        for try await event in stream {
            let workerParts = Self.parts(in: event)
            if !workerParts.isEmpty {
                await hooks.observeWorkerParts(workerParts, target)
                let text = Self.historyText(for: workerParts)
                if !text.isEmpty { workerTexts.append(text) }
            }
            yield(.worker(event))
        }

        // ルーティング文脈として履歴を保持（公式も transfer 後のサブエージェントイベントが
        // orchestrator セッションに残る）。次ターンの転送先判断が会話の流れを参照できる。
        history.append(try Self.userMessage(for: parts))
        let workerText = workerTexts.joined(separator: "\n")
        history.append(.assistant("[\(target)] \(workerText.isEmpty ? "(no text)" : workerText)"))
    }

    // MARK: - LLM routing (mirror of the official orchestrator LlmAgent)

    /// 公式 orchestrator の instruction（逐語）。可変部はロスターのみ
    /// （公式では ADK が sub_agents の description を文脈として供給する部分に相当）。
    static func instruction(roster: String) -> String {
        """
        You are an orchestrator agent. Your sole responsibility is to analyze the incoming user request, determine the user's intent, and route the task to exactly one of your expert subagents

        Agents:
        \(roster)
        """
    }

    private struct TransferToAgentTool: Tool {
        var toolName: String { "transfer_to_agent" }
        var toolDescription: String { "Transfer the conversation to the named expert subagent." }
        var inputSchema: JSONSchema {
            .object(
                properties: [
                    "agent_name": .string(description: "The name of the agent to transfer to."),
                ],
                required: ["agent_name"]
            )
        }
        // planToolCalls 専用（呼び出しの計画だけ読み、実行はルーターが転送として担う）。
        func execute(with argumentsData: Data) async throws -> ToolResult {
            .error("transfer_to_agent is handled by the router, not executed as a tool")
        }
    }

    private struct TransferArguments: Decodable {
        let agent_name: String
    }

    private func decideRoute(for parts: [Part]) async throws -> (agent: String, usage: TokenUsage) {
        let roster = await registry.rosterJSONLines()
        let response = try await client.planToolCalls(
            messages: history + [try Self.userMessage(for: parts)],
            model: model,
            tools: ToolSet { TransferToAgentTool() },
            toolChoice: .tool("transfer_to_agent"),
            systemPrompt: SystemPrompt(stringLiteral: Self.instruction(roster: roster)),
            temperature: nil,
            maxTokens: maxTokens,
            cachePolicy: cachePolicy
        )
        guard let call = response.toolCalls.first(where: { $0.name == "transfer_to_agent" }) else {
            throw AgentRuntimeError.routingFailed("no transfer_to_agent call in response")
        }
        guard let arguments = try? JSONDecoder().decode(TransferArguments.self, from: call.arguments) else {
            throw AgentRuntimeError.routingFailed("malformed transfer_to_agent arguments")
        }
        return (arguments.agent_name, response.usage)
    }

    // MARK: - Part rendering

    private static func parts(in event: StreamResponse) -> [Part] {
        switch event {
        case .task(let task):
            task.artifacts.flatMap(\.parts) + (task.status.message?.parts ?? [])
        case .statusUpdate(let update):
            update.status.message?.parts ?? []
        case .artifactUpdate(let update):
            update.artifact.parts
        case .message(let message):
            message.parts
        }
    }

    /// パーツを LLM 入力 `LLMMessage` へ。画像（`.bytes` + image/*）を貫通させ、テキストのみなら
    /// `historyText` と同一テキストの `.user(String)` を返す（ルーティング挙動の回帰なし）。
    private static func userMessage(for parts: [Part]) throws -> LLMMessage {
        try MultimodalInput.userMessage(from: parts)
    }

    /// パーツを LLM 文脈用テキストへ。テキストは逐語、構造化データはパートごと JSON 化
    /// （公式 part_converters が A2UI part を `model_dump_json` で text 化するのと同じ）。
    private static func historyText(for parts: [Part]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return parts.compactMap { part in
            switch part.content {
            case .text(let text):
                return text
            case .data:
                return (try? encoder.encode(part)).flatMap { String(data: $0, encoding: .utf8) }
            case .bytes, .uri:
                return nil
            }
        }.joined(separator: "\n")
    }
}
