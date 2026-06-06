import AgentLoopKit
import A2ACore
import A2AServer
import LLMClient
import LLMTool

/// `HostAgent`（オーケストレータ）を A2A の `AgentExecutor` として公開するアダプタ。
///
/// これにより上位オーケストレータのワーカーとして登録でき、入れ子のオーケストレーションが組める。
/// A2A の `contextId` ごとにセッションを保持し、会話を分離・継続する。
public actor HostAgentExecutor<Client: AgentCapableClient>: AgentExecutor where Client.Model: Sendable {
    private let makeHost: @Sendable () -> HostAgent<Client>
    private let artifactName: String
    private var hosts: [ContextID: HostAgent<Client>] = [:]

    public init(artifactName: String = "response", makeHost: @escaping @Sendable () -> HostAgent<Client>) {
        self.makeHost = makeHost
        self.artifactName = artifactName
    }

    public func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()

        let host = hostFor(context.contextId)
        var finalText = ""
        do {
            for try await event in await host.stream(context.getUserInput()) {
                switch event {
                case .thinking(let text):
                    if !text.isEmpty {
                        try await updater.updateStatus(.working, message: updater.newAgentMessage([.text(text)]))
                    }
                case .toolCall(_, let name):
                    try await updater.updateStatus(.working, message: updater.newAgentMessage([.text("→ \(name)")]))
                case .completed(let text):
                    finalText = text
                case .validationFailed(let issues, let willRetry):
                    if willRetry {
                        try await updater.updateStatus(.working, message: updater.newAgentMessage([.text("出力を検証中（再生成）… \(issues.count) 件の問題")]))
                    }
                case .toolResult, .inputRequired, .usage:
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
        await hosts[context.contextId]?.cancel()
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.cancel()
    }

    private func hostFor(_ contextId: ContextID) -> HostAgent<Client> {
        if let existing = hosts[contextId] { return existing }
        let host = makeHost()
        hosts[contextId] = host
        return host
    }
}
