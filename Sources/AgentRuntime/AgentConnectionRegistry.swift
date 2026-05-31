import A2ACore
import A2AServer
import A2AInProcess
import Foundation

/// 委譲先エージェントの概要（`list_agents` ツールが返す）。
public struct AgentDescriptor: Sendable, Codable, Hashable {
    public let name: String
    public let description: String
}

/// ワーカーへの送信結果。
public struct AgentSendOutcome: Sendable {
    public let agentName: String
    /// 応答テキスト（`status.message` + artifacts のテキストパートを連結）。
    public let text: String
    /// タスク状態。`nil` は Message 応答（タスク無し）。
    public let state: TaskState?
}

/// ワーカーごとの `A2AClient` 接続を保持し、A2A 越しに送信するレジストリ。
///
/// a2a-samples `RemoteAgentConnections` 相当。in-process でも remote でも `A2AClient` を
/// 注入できるので、オーケストレータは両者を区別せず同じ API で委譲できる。
/// ワーカーごとに `taskId` / `contextId` を保持し、マルチターンの会話を継続する。
public actor AgentConnectionRegistry {
    private struct Connection {
        let card: AgentCard
        let client: A2AClient
        var taskId: TaskID?
        var contextId: ContextID?
    }

    private var connections: [String: Connection] = [:]

    public init() {}

    /// 任意の `A2AClient`（in-process / REST / JSON-RPC）でワーカーを登録する。
    public func register(card: AgentCard, client: A2AClient) {
        connections[card.name] = Connection(card: card, client: client)
    }

    /// in-process ワーカーを登録する便宜メソッド。
    public func register(card: AgentCard, handler: any RequestHandler) {
        register(card: card, client: A2AClient.inProcess(handler: handler))
    }

    /// 登録済みワーカーの概要一覧。
    public func descriptors() -> [AgentDescriptor] {
        connections.values
            .map { AgentDescriptor(name: $0.card.name, description: $0.card.description) }
            .sorted { $0.name < $1.name }
    }

    /// 指定ワーカーへメッセージを送り、終端/中断状態の結果を返す。
    ///
    /// ワーカーに保存済みの `taskId` / `contextId` を引き継いでマルチターンを継続し、
    /// 応答からそれらを更新する。
    public func send(to name: String, text: String) async throws -> AgentSendOutcome {
        guard var connection = connections[name] else {
            throw AgentRuntimeError.unknownAgent(name)
        }
        let message = Message(
            messageId: MessageID(UUID().uuidString),
            role: .user,
            parts: [.text(text)],
            contextId: connection.contextId,
            taskId: connection.taskId
        )
        let response = try await connection.client.sendMessage(message)
        switch response {
        case .message(let agentMessage):
            return AgentSendOutcome(agentName: name, text: agentMessage.text, state: nil)
        case .task(let task):
            connection.taskId = task.id
            connection.contextId = task.contextId
            connections[name] = connection

            var parts: [Part] = task.status.message?.parts ?? []
            for artifact in task.artifacts {
                parts.append(contentsOf: artifact.parts)
            }
            let text = parts.compactMap(\.text).joined(separator: "\n")
            return AgentSendOutcome(agentName: name, text: text, state: task.status.state)
        }
    }

    /// 指定ワーカーの進行中タスクを A2A `cancelTask` でキャンセルする（best-effort）。
    ///
    /// - Returns: キャンセル後のタスク状態。対象タスクが無い／既に終端でキャンセル不能なら `nil`。
    @discardableResult
    public func cancel(_ name: String) async -> TaskState? {
        guard let connection = connections[name], let taskId = connection.taskId else {
            return nil
        }
        do {
            let task = try await connection.client.cancelTask(taskId)
            return task.status.state
        } catch {
            // taskNotCancelable / not found 等は無視（best-effort）。
            return nil
        }
    }

    /// 全ワーカーの進行中タスクをキャンセルする（best-effort）。
    public func cancelAll() async {
        for name in connections.keys {
            _ = await cancel(name)
        }
    }
}
