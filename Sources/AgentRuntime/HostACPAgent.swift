import ACPCore
import ACPAgent
import ACPClient
import AgentLoopKit
import LLMClient
import Foundation

/// `HostACPAgent` が発するエラー。
public enum HostACPAgentError: Error, Sendable {
    /// `prompt` / `cancel` 等の操作で、指定した `SessionId` に対応するセッションが見つからなかった。
    case unknownSession(SessionId)
    /// 対応していない ACP 拡張メソッド（`ext`）が呼ばれた。
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

    /// `HostACPAgent` を初期化する。
    ///
    /// - Parameters:
    ///   - client: ACP クライアント。`session/update` の送信（ストリーム射影・usage 通知）に使用する。
    ///   - telemetry: usage / system prompt 等の観測フック。`nil` で観測なし。
    ///   - makeHost: `HostAgent` のファクトリ。`@escaping @Sendable` クロージャで、`newSession` と `loadSession` のたびに呼ばれてセッション単位で独立したインスタンスを生成する。
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
        // 実装しているメソッドに合わせて capabilities を申告する（過少・過大申告を避ける）。
        // session list/delete/resume/close は実装済み。prompt は text + image を消費する
        // （image は base64 を LLMMessage.image へ射影）。audio/embeddedContext は未対応。
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
        // SessionId は cwd（per-session ディレクトリ）の名前から**決定的に**導出する。
        // → 永続アイデンティティと一致し、`session/load` で同じ id を復元できる。
        let id = Self.sessionId(forCwd: request.cwd)
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: request.cwd), withIntermediateDirectories: true)
        sessions[id] = Session(host: makeHost(), cwd: request.cwd)
        return NewSessionResponse(sessionId: id)
    }

    private static func sessionId(forCwd cwd: String) -> SessionId {
        let name = (cwd as NSString).lastPathComponent
        return SessionId(name.isEmpty ? UUID().uuidString : name)
    }

    // 会話履歴を per-session SSOT（cwd/conversation.json）に永続化し、session/load で復元する。
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
        // SSOT の会話履歴（cwd/conversation.json）を seed → 復元セッションでも会話を継続できる。
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

    public func prompt(_ request: PromptRequest) async throws -> PromptResponse {
        guard let session = sessions[request.sessionId] else {
            throw HostACPAgentError.unknownSession(request.sessionId)
        }
        // 画像コンテンツ（base64 + mimeType）を平坦化せず LLMMessage まで貫通させる。
        // テキストのみの入力は従来の `.user(text)` と同一出力になる（回帰なし）。
        let userMessage = try MultimodalInput.userMessage(from: request.prompt)

        let sessionId = request.sessionId
        let client = self.client
        let baseTelemetry = self.telemetry
        // ACP 境界での usage 射影。usage は意味論イベントではなく metrics（telemetry）だが、
        // その ACP 対応物 `usage_update` は session/update の標準語彙。ここで telemetry から
        // 射影してクライアントに流すことで、`AgentLoop.Event`（意味論専用）を汚さずに
        // ACP のライブゲージを成立させる。種別内訳は ACP 語彙外のため used/size のみ載せ、
        // 内訳は baseTelemetry（meter）側で扱う。
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
        // inputRequired と completed はどちらも agentMessageChunk に射影されるため、
        // 「ホストがユーザー入力を要求してターンを中断した」かは StopReason で区別する。
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
        // ターン後、会話履歴を per-session SSOT（cwd/conversation.json）へ永続化する（resume の基盤）。
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
        // 非対応の拡張通知は無視する。
    }
}
