import LLMAgentStep
import ACPCore
import ACPAgent
import ACPClient
import AgentLoopKit
import LLMClient
import Foundation

/// Failures raised at the ACP boundary.
public enum HostACPAgentError: Error, Sendable {
    /// No session exists for this id. Sessions live in memory only, so this is what a client sees
    /// after a restart if it kept an id across it.
    case unknownSession(SessionId)
    /// An ACP extension method this agent does not implement.
    case unsupported(String)
}

public extension StopReason {
    /// Non-standard: the turn stopped because the agent needs an answer from the user.
    /// Show an input prompt and send the reply as the next turn.
    static let inputRequired = StopReason("input_required")
}

/// Exposes an orchestrator over ACP, so an app can drive it as a client.
///
/// This is the vertical boundary — app to host — while delegation to workers stays horizontal and
/// A2A inside the host. One orchestrator is kept per session so conversations stay separate.
///
/// Only the semantic events reach the client as updates; usage is projected separately as its ACP
/// counterpart, and the rendered prompt is never sent. Conversation history is written to a file
/// under the session's working directory after every turn, which is what makes reloading a
/// session resume it.
public actor HostACPAgent<Client: AgentCapableClient>: ACPAgent where Client.Model: Sendable {
    private let client: any ACPClient
    private let makeHost: @Sendable () -> HostAgent<Client>
    private let telemetry: AgentTelemetrySink?

    private struct Session {
        let host: HostAgent<Client>
        let cwd: String
    }
    private var sessions: [SessionId: Session] = [:]

    /// Creates an ACP agent that builds one orchestrator per session.
    ///
    /// - Parameters:
    ///   - client: Where updates are sent. A client that blocks here stalls the turn.
    ///   - telemetry: Also receives usage and the rendered prompt. Usage reaches the ACP client
    ///     regardless; this is the extra sink for meters and debug views. `nil` observes nothing.
    ///   - makeHost: Called once per new or loaded session. Each call must return a fresh
    ///     orchestrator — returning a shared one merges the conversations.
    public init(
        client: any ACPClient,
        telemetry: AgentTelemetrySink? = nil,
        makeHost: @escaping @Sendable () -> HostAgent<Client>
    ) {
        self.client = client
        self.telemetry = telemetry
        self.makeHost = makeHost
    }

    // MARK: - Negotiation

    public func initialize(_ request: InitializeRequest) async throws -> InitializeResponse {
        // Declared to match what is actually implemented, so a client is neither denied something
        // that works nor promised something that does not. Prompts accept text and images; audio
        // is skipped.
        InitializeResponse(
            protocolVersion: .v1,
            agentCapabilities: AgentCapabilities(
                loadSession: true,
                promptCapabilities: PromptCapabilities(image: true),
                sessionCapabilities: SessionCapabilities(
                    list: .init(),
                    delete: .init(),
                    resume: .init(),
                    close: .init()
                )
            )
        )
    }

    public func authenticate(_ request: AuthenticateRequest) async throws -> AuthenticateResponse {
        AuthenticateResponse()
    }

    // MARK: - Session lifecycle

    public func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        // The id is derived from the working directory's name so that it matches the identity on
        // disk and a reload gets the same id back. Two directories with the same last component
        // therefore collide, and the second session replaces the first.
        let id = Self.sessionId(forCwd: request.cwd)
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: request.cwd), withIntermediateDirectories: true)
        sessions[id] = Session(host: makeHost(), cwd: request.cwd)
        return NewSessionResponse(sessionId: id)
    }

    private static func sessionId(forCwd cwd: String) -> SessionId {
        let name = (cwd as NSString).lastPathComponent
        return SessionId(name.isEmpty ? UUID().uuidString : name)
    }

    // The conversation is stored per session under its working directory. Both directions fail
    // quietly: a write that fails is not reported, and a missing or unreadable file loads as an
    // empty conversation, so a reload can silently start over instead of resuming.
    nonisolated private static func conversationURL(cwd: String) -> URL {
        URL(fileURLWithPath: cwd).appendingPathComponent("conversation.json")
    }
    nonisolated private static func persistConversation(_ messages: [LLMMessage], cwd: String) {
        let url = conversationURL(cwd: cwd)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(messages) { try? data.write(to: url, options: .atomic) }
    }
    nonisolated private static func loadConversation(cwd: String) -> [LLMMessage] {
        guard let data = try? Data(contentsOf: conversationURL(cwd: cwd)),
              let messages = try? JSONDecoder().decode([LLMMessage].self, from: data) else { return [] }
        return messages
    }

    public func loadSession(_ request: LoadSessionRequest) async throws -> LoadSessionResponse {
        // Seed the new orchestrator from the stored conversation so the reloaded session continues.
        let host = makeHost()
        await host.loadHistory(Self.loadConversation(cwd: request.cwd))
        sessions[request.sessionId] = Session(host: host, cwd: request.cwd)
        return LoadSessionResponse()
    }

    public func listSessions(_ request: ListSessionsRequest) async throws -> ListSessionsResponse {
        ListSessionsResponse(sessions: sessions.map { SessionInfo(sessionId: $0.key, cwd: $0.value.cwd) })
    }

    public func resumeSession(_ request: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        ResumeSessionResponse()
    }

    public func deleteSession(_ request: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        if let session = sessions.removeValue(forKey: request.sessionId) { await session.host.close() }
        return DeleteSessionResponse()
    }

    public func closeSession(_ request: CloseSessionRequest) async throws -> CloseSessionResponse {
        if let session = sessions.removeValue(forKey: request.sessionId) { await session.host.close() }
        return CloseSessionResponse()
    }

    public func setSessionMode(_ request: SetSessionModeRequest) async throws -> SetSessionModeResponse {
        SetSessionModeResponse()
    }

    public func setSessionConfigOption(_ request: SetSessionConfigOptionRequest) async throws -> SetSessionConfigOptionResponse {
        SetSessionConfigOptionResponse(configOptions: [])
    }

    // MARK: - Prompt turn

    /// Runs one turn and streams it to the client as updates.
    ///
    /// Cancellation is reported as a stop reason rather than thrown, and the partial conversation
    /// is still persisted. Any other failure propagates after the updates already sent.
    ///
    /// - Throws: `HostACPAgentError.unknownSession` for an id that was never created or loaded,
    ///   or a conversion failure for an attachment the model cannot accept.
    public func prompt(_ request: PromptRequest) async throws -> PromptResponse {
        guard let session = sessions[request.sessionId] else {
            throw HostACPAgentError.unknownSession(request.sessionId)
        }
        // Attachments are carried through to the model rather than flattened away. An attachment
        // the model cannot accept throws here, before the turn starts.
        let userMessage = try MultimodalInput.userMessage(from: request.prompt)

        let sessionId = request.sessionId
        let client = self.client
        let baseTelemetry = self.telemetry
        // Usage is a metric, but its ACP counterpart is part of the standard update vocabulary, so
        // it is projected here rather than being mixed into the event stream. ACP has no field for
        // the breakdown by token kind, so only the total is sent; anything finer belongs on the
        // telemetry sink. Failures sending it are ignored — a dropped gauge update must not kill
        // the turn.
        let telemetry: AgentTelemetrySink = { event in
            if case let .usage(usage, _) = event {
                let used = UInt64(max(0, usage.inputTokens + usage.outputTokens))
                try? await client.sessionUpdate(SessionNotification(
                    sessionId: sessionId,
                    update: .usageUpdate(UsageUpdate(used: used, size: 0))
                ))
            }
            await baseTelemetry?(event)
        }
        // A question and a finished answer both project onto the same kind of update, so the stop
        // reason is the only thing that tells a client the turn is waiting on the user.
        var stopReason = StopReason.endTurn
        do {
            for try await event in await session.host.stream(userMessage, telemetry: telemetry) {
                if case .inputRequired = event { stopReason = .inputRequired }
                guard let update = AgentLoop<Client>.sessionUpdate(for: event) else { continue }
                try await client.sessionUpdate(SessionNotification(sessionId: sessionId, update: update))
            }
        } catch is CancellationError {
            stopReason = .cancelled
        }
        // Persist after every turn, cancelled ones included, so a reload resumes from here.
        Self.persistConversation(await session.host.messages, cwd: session.cwd)
        return PromptResponse(stopReason: stopReason)
    }

    public func cancel(_ notification: CancelNotification) async throws {
        await sessions[notification.sessionId]?.host.cancel()
    }

    public func logout(_ request: LogoutRequest) async throws -> LogoutResponse {
        LogoutResponse()
    }

    public func ext(_ request: ExtRequest) async throws -> ExtResponse {
        throw HostACPAgentError.unsupported(request.method)
    }

    public func extNotification(_ notification: ExtNotification) async throws {
        // No extension notifications are handled; ignoring them is the contract for notifications.
    }
}
