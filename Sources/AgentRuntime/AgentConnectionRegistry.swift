import A2ACore
import A2AClientCore
import A2AServer
import A2AInProcess
import LLMClient
import Foundation

public struct AgentDescriptor: Sendable, Codable, Hashable {
    public let name: String
    public let description: String
}

public struct AgentSendOutcome: Sendable {
    public let agentName: String
    public let text: String
    /// `nil` は Message 応答（タスク無し）。
    public let state: TaskState?
    /// ワーカーが消費したトークン使用量（artifact metadata 由来。無ければ nil）。
    public let usage: TokenUsage?
}

/// ワーカーごとの `A2AClient` 接続を保持し A2A 越しに委譲する（a2a-samples `RemoteAgentConnections` 相当）。
///
/// in-process / remote を問わず `A2AClient` を注入でき、ワーカーごとに `taskId` / `contextId` を
/// 保持してマルチターンを継続する。`send` は配信モードに沿ってストリームを終端まで消費し、
/// 進捗を `observer` に流しつつ usage と終端状態を集約して返す。
/// 公式 `host_agent` の session state（active_agent / session_active）も保持し、root instruction に供給する。
public actor AgentConnectionRegistry {
    private struct Connection {
        let card: AgentCard
        let client: A2AClient
        var taskId: TaskID?
        var contextId: ContextID?
    }

    private var connections: [String: Connection] = [:]
    private let mode: DeliveryMode
    private let observer: DelegationObserver?

    /// 直近に委譲したエージェント（公式 `check_state` の `state['agent']` 相当）。
    private var lastAgent: String?
    /// 委譲セッションが継続中か（公式 `session_active`）。終端状態で false。
    private var sessionActive = false

    /// root instruction に出す現在エージェント（継続中のみ名前、なければ `"None"`）。
    public var activeAgent: String { sessionActive ? (lastAgent ?? "None") : "None" }

    public init(mode: DeliveryMode = .streaming, observer: DelegationObserver? = nil) {
        self.mode = mode
        self.observer = observer
    }

    public func register(card: AgentCard, client: A2AClient) {
        connections[card.name] = Connection(card: card, client: client)
    }

    public func register(card: AgentCard, handler: any RequestHandler) {
        register(card: card, client: A2AClient.inProcess(handler: handler))
    }

    /// in-process ワーカーを `AgentExecutor` から直接登録する糖衣。
    public func register(card: AgentCard, executor: any AgentExecutor) {
        register(card: card, handler: DefaultRequestHandler(agentCard: card, executor: executor))
    }

    public func descriptors() -> [AgentDescriptor] {
        connections.values
            .map { AgentDescriptor(name: $0.card.name, description: $0.card.description) }
            .sorted { $0.name < $1.name }
    }

    /// 公式 `register_agent_card` の `self.agents`（`'\n'.join(json.dumps({name,description}))`）相当。
    /// root instruction の `Agents:` セクションへそのまま差し込む（1 行 1 JSON）。
    public func rosterJSONLines() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return descriptors().compactMap { descriptor in
            (try? encoder.encode(descriptor)).flatMap { String(data: $0, encoding: .utf8) }
        }.joined(separator: "\n")
    }

    /// 保存済みの `taskId` / `contextId` を引き継いで送信し、配信モードに沿ってストリームを
    /// **終端まで消費**してから返す（公式 `send_message` 相当）。待機中の各イベントは `observer` に流す。
    public func send(to name: String, text: String) async throws -> AgentSendOutcome {
        guard var connection = connections[name] else {
            throw AgentRuntimeError.unknownAgent(name)
        }
        lastAgent = name
        sessionActive = true
        let delegationId = UUID().uuidString
        await observer?(.started(id: delegationId, agent: name, label: String(text.prefix(60))))

        let message = Message(
            messageId: MessageID(UUID().uuidString),
            role: .user,
            parts: [.text(text)],
            contextId: connection.contextId,
            taskId: connection.taskId
        )

        var artifacts: [String: String] = [:]
        var messageText = ""
        // 終端/中断イベントの status メッセージのみ採用（input-required の質問等）。途中の進捗ノートは除外。
        var finalStatusMessage = ""
        var finalState: TaskState?
        var usage: TokenUsage?

        do {
            for try await event in connection.client.events(message, mode: mode) {
                await observer?(.progress(id: delegationId, agent: name, event))
                switch event {
                case .task(let task):
                    connection.taskId = task.id
                    connection.contextId = task.contextId
                    finalState = task.status.state
                    for artifact in task.artifacts {
                        artifacts[artifact.artifactId.rawValue] = artifact.parts.compactMap(\.text).joined()
                        if let decoded = UsageMetadata.decode(artifact.metadata) { usage = decoded }
                    }
                    if task.status.state.isTerminal || task.status.state.isInterrupted,
                       let statusMessage = task.status.message {
                        finalStatusMessage = statusMessage.parts.compactMap(\.text).joined()
                    }
                case .statusUpdate(let update):
                    connection.taskId = update.taskId
                    finalState = update.status.state
                    if update.status.state.isTerminal || update.status.state.isInterrupted,
                       let statusMessage = update.status.message {
                        finalStatusMessage = statusMessage.parts.compactMap(\.text).joined()
                    }
                case .artifactUpdate(let update):
                    connection.taskId = update.taskId
                    let id = update.artifact.artifactId.rawValue
                    let chunk = update.artifact.parts.compactMap(\.text).joined()
                    artifacts[id] = update.append ? (artifacts[id] ?? "") + chunk : chunk
                    if let decoded = UsageMetadata.decode(update.artifact.metadata) { usage = decoded }
                case .message(let agentMessage):
                    messageText += agentMessage.text
                }
            }
        } catch {
            await observer?(.failed(id: delegationId, agent: name, error: "\(error)"))
            throw error
        }

        connections[name] = connection
        // 公式 session_active: 終端状態（completed/canceled/failed）で非継続。中断（input-required）は継続。
        if let state = finalState {
            sessionActive = !state.isTerminal
        } else {
            sessionActive = false
        }

        var pieces: [String] = []
        let artifactText = artifacts.values.joined(separator: "\n")
        if !artifactText.isEmpty { pieces.append(artifactText) }
        if !finalStatusMessage.isEmpty { pieces.append(finalStatusMessage) }
        if !messageText.isEmpty { pieces.append(messageText) }
        let aggregated = pieces.joined(separator: "\n")

        if let usage { await observer?(.usage(id: delegationId, agent: name, usage: usage)) }
        await observer?(.finished(id: delegationId, agent: name, text: aggregated, state: finalState))
        return AgentSendOutcome(agentName: name, text: aggregated, state: finalState, usage: usage)
    }

    /// パーツ保存版の委譲（公式 A2UI orchestrator のパススルー転送相当）。
    ///
    /// `send(to:text:)` がテキストへ平坦化・集約するのに対し、こちらは構造化パート
    /// （A2UI DataPart 等）と message metadata をそのままワーカーへ送り、`StreamResponse` を
    /// 生で流す。消費側（ルーター）がイベントからパーツを取り出してクライアントへ
    /// パススルーする。`taskId` / `contextId` / `activeAgent` の管理と observer への
    /// 進捗通知は `send(to:text:)` と同じ。
    public func sendStream(
        to name: String,
        parts: [Part],
        metadata: A2AMetadata? = nil
    ) throws -> AsyncThrowingStream<StreamResponse, Error> {
        guard let connection = connections[name] else {
            throw AgentRuntimeError.unknownAgent(name)
        }
        lastAgent = name
        sessionActive = true
        let delegationId = UUID().uuidString
        let label = parts.compactMap(\.text).joined().prefix(60)

        let message = Message(
            messageId: MessageID(UUID().uuidString),
            role: .user,
            parts: parts,
            contextId: connection.contextId,
            taskId: connection.taskId,
            metadata: metadata
        )
        let client = connection.client
        let mode = self.mode
        let observer = self.observer

        return AsyncThrowingStream { continuation in
            let task = Task {
                await observer?(.started(id: delegationId, agent: name, label: String(label)))
                var finalState: TaskState?
                do {
                    for try await event in client.events(message, mode: mode) {
                        await observer?(.progress(id: delegationId, agent: name, event))
                        await self.recordIdentifiers(from: event, for: name)
                        if let state = Self.taskState(of: event) { finalState = state }
                        if let usage = Self.usage(of: event) {
                            await observer?(.usage(id: delegationId, agent: name, usage: usage))
                        }
                        continuation.yield(event)
                    }
                    await self.finishDelegation(finalState: finalState)
                    await observer?(.finished(id: delegationId, agent: name, text: "", state: finalState))
                    continuation.finish()
                } catch {
                    await observer?(.failed(id: delegationId, agent: name, error: "\(error)"))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func recordIdentifiers(from event: StreamResponse, for name: String) {
        guard var connection = connections[name] else { return }
        switch event {
        case .task(let task):
            connection.taskId = task.id
            connection.contextId = task.contextId
        case .statusUpdate(let update):
            connection.taskId = update.taskId
        case .artifactUpdate(let update):
            connection.taskId = update.taskId
        case .message:
            break
        }
        connections[name] = connection
    }

    private func finishDelegation(finalState: TaskState?) {
        // send(to:text:) と同じ: 終端状態（completed/canceled/failed）で非継続。中断（input-required）は継続。
        if let state = finalState {
            sessionActive = !state.isTerminal
        } else {
            sessionActive = false
        }
    }

    private static func taskState(of event: StreamResponse) -> TaskState? {
        switch event {
        case .task(let task): task.status.state
        case .statusUpdate(let update): update.status.state
        case .artifactUpdate, .message: nil
        }
    }

    private static func usage(of event: StreamResponse) -> TokenUsage? {
        switch event {
        case .task(let task):
            task.artifacts.lazy.compactMap { UsageMetadata.decode($0.metadata) }.first
        case .artifactUpdate(let update):
            UsageMetadata.decode(update.artifact.metadata)
        case .statusUpdate, .message:
            nil
        }
    }

    /// 進行中タスクを A2A `cancelTask` でキャンセル（best-effort）。対象が無い／終端なら `nil`。
    @discardableResult
    public func cancel(_ name: String) async -> TaskState? {
        guard let connection = connections[name], let taskId = connection.taskId else {
            return nil
        }
        return try? await connection.client.cancelTask(taskId).status.state
    }

    public func cancelAll() async {
        for name in connections.keys {
            _ = await cancel(name)
        }
    }
}
