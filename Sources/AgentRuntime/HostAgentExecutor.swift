import AgentLoopKit
import A2ACore
import A2AServer
import LLMClient
import LLMTool
import LLMAgentStep

/// Exposes an orchestrator as an A2A worker, so orchestrators can nest.
///
/// One host is created per context id and kept for the lifetime of this executor: conversations
/// stay separate, and a follow-up on the same context continues where it left off. Nothing
/// evicts a context, so a long-lived executor accumulates one host per conversation it has seen.
///
/// A turn that throws is reported as a failed task rather than propagated, so the caller sees the
/// error as text on the task and this method still returns normally.
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
        // Deltas are buffered and posted as one status update when a tool call comes along:
        // a status update per chunk is noise on the A2A wire. The buffer is bounded by the
        // step's own text, and is dropped rather than posted if the turn ends without a tool call.
        var stepText = ""
        do {
            for try await event in await host.stream(context.userInput()) {
                switch event {
                case .textDelta(let delta):
                    stepText += delta
                case .toolCall(_, let name, _):
                    if !stepText.isEmpty {
                        try await updater.updateStatus(.working, message: updater.makeAgentMessage([.text(stepText)]))
                        stepText = ""
                    }
                    try await updater.updateStatus(.working, message: updater.makeAgentMessage([.text("→ \(name)")]))
                case .completed(let text):
                    finalText = text
                case .toolApprovalRequired(_, _, _, let request):
                    // There is no approval UI on this path, so the request is only reported as
                    // text. Nothing here can send a verdict back, and the tool never runs.
                    try await updater.updateStatus(.working, message: updater.makeAgentMessage([.text(request.summary)]))
                case .toolResult, .inputRequired, .thinkingDelta:
                    break
                }
            }
            await updater.addArtifact([.text(finalText)], name: artifactName)
            try await updater.complete()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? await updater.fail(message: updater.makeAgentMessage([.text("\(error)")]))
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
