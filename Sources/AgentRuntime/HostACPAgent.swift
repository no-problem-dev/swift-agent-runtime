import ACPCore
import ACPAgent
import ACPClient
import AgentLoopKit
import LLMClient
import Foundation

public enum HostACPAgentError: Error, Sendable {
    case unknownSession(SessionId)
    case unsupported(String)
}

public extension StopReason {
    /// 非標準（runtime 拡張）: ホストがユーザー入力を要求してターンを中断した。
    /// クライアントは入力 UI を出し、回答を次の `prompt` として送り直す。
    static let inputRequired = StopReason("input_required")
}

/// `HostAgent`（内部で A2A ワーカーを回すオーケストレータ）を **ACP エージェント**として露出する。
///
/// app↔host の縦境界を ACP で実現する: アプリは ACP クライアント（`prompt` で駆動）、これは ACP
/// エージェント（`session/update` をストリーム）。ワーカー委譲は host 内部で A2A のまま（横）。
/// セッションごとに `HostAgent` を保持し、会話を分離・継続する。意味論イベントだけを
/// `session/update` に射影し、usage/systemPrompt 等の telemetry は別 sink で受ける（ACP 語彙外）。
public actor HostACPAgent<Client: AgentCapableClient>: ACPAgent where Client.Model: Sendable {
    private let client: any ACPClient
    private let makeHost: @Sendable () -> HostAgent<Client>
    private let telemetry: AgentTelemetrySink?

    private struct Session {
        let host: HostAgent<Client>
        let cwd: String
    }
    private var sessions: [SessionId: Session] = [:]

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
        InitializeResponse(protocolVersion: .v1, agentCapabilities: AgentCapabilities(loadSession: true))
    }

    public func authenticate(_ request: AuthenticateRequest) async throws -> AuthenticateResponse {
        AuthenticateResponse()
    }

    // MARK: - Session lifecycle

    public func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        let id = SessionId(UUID().uuidString)
        sessions[id] = Session(host: makeHost(), cwd: request.cwd)
        return NewSessionResponse(sessionId: id)
    }

    public func loadSession(_ request: LoadSessionRequest) async throws -> LoadSessionResponse {
        // P4 で会話履歴の復元（session/update 再生）を実装する。今は空セッションを用意する。
        if sessions[request.sessionId] == nil {
            sessions[request.sessionId] = Session(host: makeHost(), cwd: request.cwd)
        }
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

    public func prompt(_ request: PromptRequest) async throws -> PromptResponse {
        guard let session = sessions[request.sessionId] else {
            throw HostACPAgentError.unknownSession(request.sessionId)
        }
        let text = request.prompt.compactMap { block -> String? in
            if case let .text(content) = block { return content.text }
            return nil
        }.joined()

        let sessionId = request.sessionId
        let client = self.client
        // inputRequired と completed はどちらも agentMessageChunk に射影されるため、
        // 「ホストがユーザー入力を要求してターンを中断した」かは StopReason で区別する。
        var stopReason = StopReason.endTurn
        do {
            for try await event in await session.host.stream(text, telemetry: telemetry) {
                if case .inputRequired = event { stopReason = .inputRequired }
                guard let update = AgentLoop<Client>.sessionUpdate(for: event) else { continue }
                try await client.sessionUpdate(SessionNotification(sessionId: sessionId, update: update))
            }
        } catch is CancellationError {
            return PromptResponse(stopReason: .cancelled)
        }
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
        // 非対応の拡張通知は無視する。
    }
}
