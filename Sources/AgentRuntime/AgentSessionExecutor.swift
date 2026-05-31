import AgentLoopKit
import A2ACore
import A2AServer
import LLMClient
import LLMTool

/// `AgentSession`（オーケストレータ）を A2A の `AgentExecutor` として公開するアダプタ。
///
/// これにより上位オーケストレータのワーカーとして登録でき、入れ子のオーケストレーションが組める。
/// A2A の `contextId` ごとにセッションを保持し、会話を分離・継続する。
public actor AgentSessionExecutor<Client: AgentCapableClient>: AgentExecutor where Client.Model: Sendable {
    private let makeSession: @Sendable () -> AgentSession<Client>
    private let artifactName: String
    private var sessions: [ContextID: AgentSession<Client>] = [:]

    public init(artifactName: String = "response", makeSession: @escaping @Sendable () -> AgentSession<Client>) {
        self.makeSession = makeSession
        self.artifactName = artifactName
    }

    public func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()

        let session = sessionFor(context.contextId)
        var finalText = ""
        do {
            for try await event in await session.stream(context.getUserInput()) {
                switch event {
                case .thinking(let text):
                    if !text.isEmpty {
                        try await updater.updateStatus(.working, message: updater.newAgentMessage([.text(text)]))
                    }
                case .toolCall(_, let name):
                    try await updater.updateStatus(.working, message: updater.newAgentMessage([.text("→ \(name)")]))
                case .completed(let text):
                    finalText = text
                case .toolResult, .inputRequired:
                    break
                }
            }
            await updater.addArtifact([.text(finalText)], name: artifactName)
            try await updater.complete()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? await updater.failed(message: updater.newAgentMessage([.text("\(error)")]))
        }
    }

    public func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {
        await sessions[context.contextId]?.cancel()
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.cancel()
    }

    private func sessionFor(_ contextId: ContextID) -> AgentSession<Client> {
        if let existing = sessions[contextId] { return existing }
        let session = makeSession()
        sessions[contextId] = session
        return session
    }
}
