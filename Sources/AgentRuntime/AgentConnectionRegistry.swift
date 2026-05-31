import A2ACore
import A2AServer
import A2AInProcess
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
}

/// ワーカーごとの `A2AClient` 接続を保持し A2A 越しに委譲する（a2a-samples `RemoteAgentConnections` 相当）。
///
/// in-process / remote を問わず `A2AClient` を注入でき、ワーカーごとに `taskId` / `contextId` を
/// 保持してマルチターンを継続する。
public actor AgentConnectionRegistry {
    private struct Connection {
        let card: AgentCard
        let client: A2AClient
        var taskId: TaskID?
        var contextId: ContextID?
    }

    private var connections: [String: Connection] = [:]

    public init() {}

    public func register(card: AgentCard, client: A2AClient) {
        connections[card.name] = Connection(card: card, client: client)
    }

    public func register(card: AgentCard, handler: any RequestHandler) {
        register(card: card, client: A2AClient.inProcess(handler: handler))
    }

    public func descriptors() -> [AgentDescriptor] {
        connections.values
            .map { AgentDescriptor(name: $0.card.name, description: $0.card.description) }
            .sorted { $0.name < $1.name }
    }

    /// 保存済みの `taskId` / `contextId` を引き継いで送信し、終端/中断状態の結果を返す。
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
