import AgentLoopKit
import A2ACore
import A2AServer
import LLMClient
import LLMTool
import LLMAgentStep

/// Exposes an orchestrator as an A2A worker, so orchestrators can nest.
///
/// One host is created per context id: conversations stay separate, and a follow-up on the same
/// context continues where it left off. Only the most recently used `retainedContexts` of them are
/// kept — each host holds a whole conversation, so an executor that runs for a long time would
/// otherwise accumulate one for every conversation it has ever seen. A context whose host has been
/// released is not an error: the next message on it simply starts a fresh conversation.
///
/// A turn that throws is reported as a failed task rather than propagated, so the caller sees the
/// error as text on the task and this method still returns normally.
public actor HostAgentExecutor<Client: AgentCapableClient>: AgentExecutor where Client.Model: Sendable {
    private let makeHost: @Sendable () -> HostAgent<Client>
    private let artifactName: String
    private var hosts: [ContextID: HostAgent<Client>] = [:]
    /// Context ids in order of use, least recent first — the order eviction follows.
    private var contextOrder: [ContextID] = []
    private let retainedContexts: Int

    /// How many conversations an executor keeps when nothing else is said.
    public static var defaultRetainedContexts: Int { 32 }

    /// - Parameters:
    ///   - retainedContexts: How many contexts keep their conversation. Once more than this have
    ///     been seen, the least recently used host is closed and dropped, and a later message on
    ///     that context starts over. Values below one are treated as one.
    public init(
        artifactName: String = "response",
        retainedContexts: Int = HostAgentExecutor.defaultRetainedContexts,
        makeHost: @escaping @Sendable () -> HostAgent<Client>
    ) {
        self.makeHost = makeHost
        self.artifactName = artifactName
        self.retainedContexts = max(1, retainedContexts)
    }

    public func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()

        let host = await hostFor(context.contextId)
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

    private func hostFor(_ contextId: ContextID) async -> HostAgent<Client> {
        contextOrder.removeAll { $0 == contextId }
        contextOrder.append(contextId)
        if let existing = hosts[contextId] { return existing }
        let host = makeHost()
        hosts[contextId] = host
        // Closing the evicted host, rather than only dropping it, releases the prompt caches its
        // client may be paying to hold.
        while contextOrder.count > retainedContexts {
            let oldest = contextOrder.removeFirst()
            if let evicted = hosts.removeValue(forKey: oldest) { await evicted.close() }
        }
        return host
    }
}
