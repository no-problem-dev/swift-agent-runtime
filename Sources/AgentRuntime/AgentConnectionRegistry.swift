import A2ACore
import A2AClientCore
import A2AServer
import A2AInProcess
import LLMClient
import Foundation

/// ワーカーの識別名と説明を束ねる値型。`AgentConnectionRegistry.descriptors()` の要素として返され、`list_remote_agents` ツールや LLM の root instruction に差し込まれる。
public struct AgentDescriptor: Sendable, Codable, Hashable {
    public let name: String
    public let description: String
}

/// `send(to:text:)` 完了後のブロッキング委譲結果。artifact テキスト・終端状態・usage をまとめる。
public struct AgentSendOutcome: Sendable {
    public let name: String
    public let text: String
    /// `nil` は Message 応答（タスク無し）。
    public let state: TaskState?
    /// ワーカーが消費したトークン使用量（artifact metadata 由来。無ければ nil）。
    public let usage: TokenUsage?
}

/// 非ブロッキング委譲（A2A `returnImmediately`）の即時ハンドル。
/// ワーカーはサーバ側でバックグラウンド実行を継続し、後で `checkTask` / `listRunningTasks` で確認する。
public struct AgentTaskHandle: Sendable {
    public let name: String
    /// 生成されたタスク ID。ワーカーが Message を即返した場合（タスク無し）は `nil`。
    public let taskId: TaskID?
    public let contextId: ContextID?
    /// 即時スナップショットの状態（通常 submitted / working）。
    public let state: TaskState?
    /// ワーカーが Message を即返した場合の本文（タスクなら空）。
    public let immediateText: String
}

/// 背景委譲の完了をどう受け取るか。A2A 標準の3方式は排他でなく**層として同時併用**できる
/// （すべて同じ observer イベントを finished-once で冪等に流すので、何個 ON でも完了は1回）。
/// - `subscribe`: SSE / resubscribe。背景で走るワーカーをライブで見届ける（進捗の窓）。
/// - `pollInterval`: `tasks/get` を間隔で。stuck（ハング）検知の安全網。頻繁は無意味なので長め（既定2分）。
/// - `push`: `PushNotificationConfig` 登録 → 完了でワーカーが能動的に割り込み通知（in-process は Swift イベント）。
public struct BackgroundDelivery: Sendable, Equatable {
    public var subscribe: Bool
    public var push: Bool
    /// poll する間隔（nil = poll しない）。
    public var pollInterval: Duration?

    public init(subscribe: Bool = true, push: Bool = true, pollInterval: Duration? = .seconds(120)) {
        self.subscribe = subscribe
        self.push = push
        self.pollInterval = pollInterval
    }

    /// 3方式すべて（poll は 2 分）。既定。
    public static let all = BackgroundDelivery()
    public static let subscribeOnly = BackgroundDelivery(subscribe: true, push: false, pollInterval: nil)
    public static let pushOnly = BackgroundDelivery(subscribe: false, push: true, pollInterval: nil)
    public static func pollOnly(every: Duration) -> BackgroundDelivery {
        BackgroundDelivery(subscribe: false, push: false, pollInterval: every)
    }
}

/// 進行中／完了タスクのスナップショット（`checkTask` / `listRunningTasks` の戻り値）。
public struct AgentTaskStatus: Sendable {
    /// ワーカー名。
    public let name: String
    /// A2A タスク ID。
    public let taskId: TaskID
    /// タスクの現在状態。
    public let state: TaskState
    /// artifact と（終端/中断時の）status メッセージを連結した集約テキスト。ホストの LLM が `check_task` の返答として参照する。
    public let text: String
    /// artifact metadata から取得したトークン使用量。usage が記録されていなければ `nil`。
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
    /// ワーカー usage の metrics 側帯シンク。委譲ライフサイクル（observer）とは別経路。
    private let usageObserver: DelegationUsageObserver?
    /// 背景委譲（delegate_async）の既定の完了受け取り方。delegateAsync で個別指定が無ければこれを使う。
    private let defaultDelivery: BackgroundDelivery

    /// 直近に委譲したエージェント（公式 `check_state` の `state['agent']` 相当）。
    private var lastAgent: String?
    /// 委譲セッションが継続中か（公式 `session_active`）。終端状態で false。
    private var sessionActive = false

    /// ワーカー handler に渡す in-process push sender を生成する。
    ///
    /// 生成した sender を `DefaultRequestHandler` の `pushSender` に渡すと、ワーカーが完了した際に
    /// `ingestPush` 経由で registry へ通知が届き、`.push` 配信が有効になる。
    /// `register(card:executor:)` は自動的に呼ぶが、クライアントを直接登録する場合は手動で注入する。
    public func makePushSender() -> InProcessPushNotificationSender {
        InProcessPushNotificationSender { [weak self] event, config in
            await self?.ingestPush(event, config)
        }
    }

    private struct TrackedTask {
        let agentName: String
        /// この委譲を一意に識別する ID（observer のレーン相関・終端通知用）。
        let delegationId: String
        var snapshot: A2ATask
        /// 終端を観測して finished/最終描画を一度だけ発火したか。
        var finished: Bool
        /// 背景監視（subscribe / poll）の Task ハンドル群。cancel 時に全停止する（push は監視ループ無し）。
        var monitors: [Task<Void, Never>]
    }
    // 非ブロッキング委譲したタスク（taskId -> 所有ワーカー＋直近スナップショット）。
    // 終端後も保持する（check_task で完了後の成果物を取得できるようにするため）。
    // snapshot は returnImmediately の即時応答を保持し、getTask が永続化に追いつく前の
    // 取りこぼし（404）を防ぐフォールバックに使う。
    private var delegatedTasks: [TaskID: TrackedTask] = [:]
    // delegateAsync が sendMessage 応答を受けて追跡登録する前に届いた push イベントの一時保管
    // （delegationId 別）。instant ワーカーは登録前に完了 push まで終えることがあり、
    // ここで保留しないと push が silent drop されて `.pushOnly` 配信が届かない。
    private var pendingPushes: [String: [StreamResponse]] = [:]

    /// root instruction に出す現在エージェント（継続中のみ名前、なければ `"None"`）。
    public var activeAgent: String { sessionActive ? (lastAgent ?? "None") : "None" }

    public init(mode: DeliveryMode = .streaming, observer: DelegationObserver? = nil, usageObserver: DelegationUsageObserver? = nil, defaultDelivery: BackgroundDelivery = .all) {
        self.mode = mode
        self.observer = observer
        self.usageObserver = usageObserver
        self.defaultDelivery = defaultDelivery
    }

    /// `A2AClient` を直接指定してワーカーを登録する（リモート接続向け）。
    public func register(card: AgentCard, client: A2AClient) {
        connections[card.name] = Connection(card: card, client: client)
    }

    /// in-process `RequestHandler` からワーカーを登録する。
    public func register(card: AgentCard, handler: any RequestHandler) {
        register(card: card, client: A2AClient.inProcess(handler: handler))
    }

    /// in-process ワーカーを `AgentExecutor` から直接登録する糖衣。ワーカー専用の push config store ＋
    /// in-process sender を注入するので、`.push` 配信が有効になる。
    public func register(card: AgentCard, executor: any AgentExecutor) {
        let handler = DefaultRequestHandler(
            agentCard: card, executor: executor,
            pushConfigStore: InMemoryPushNotificationConfigStore(),
            pushSender: makePushSender()
        )
        register(card: card, handler: handler)
    }

    /// 登録済みワーカーの名前と説明を昇順ソートで返す。
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

        if let usage { await usageObserver?(delegationId, name, usage) }
        await observer?(.finished(id: delegationId, agent: name, text: aggregated, state: finalState))
        return AgentSendOutcome(name: name, text: aggregated, state: finalState, usage: usage)
    }

    /// パーツ保存版の委譲（公式 A2UI orchestrator のパススルー転送相当）。
    ///
    /// `send(to:text:)` がテキストへ平坦化・集約するのに対し、こちらは構造化パート
    /// （A2UI DataPart 等）と message metadata をそのままワーカーへ送り、`StreamResponse` を
    /// 生で流す。消費側（ルーター）がイベントからパーツを取り出してクライアントへ
    /// パススルーする。`taskId` / `contextId` / `activeAgent` の管理と observer への
    /// 進捗通知は `send(to:text:)` と同じ。
    public func stream(
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
        let usageObserver = self.usageObserver

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
                            await usageObserver?(delegationId, name, usage)
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

    // MARK: - 非ブロッキング委譲（バックグラウンドエージェント）

    /// `returnImmediately` でタスクを生成して即ハンドルを返す（A2A バックグラウンドエージェント）。
    ///
    /// ストリームを終端まで待つ `send(to:text:)` と異なり、ワーカーはサーバ側で実行を継続する。
    /// 呼び出し側（ホスト）は `checkTask` / `listRunningTasks` で後から状況・成果物を確認する。
    /// 毎回新しいタスク（`taskId` 無し）で送るため、同一ワーカーへの並列委譲も独立タスクになる。
    public func delegateAsync(to name: String, text: String, delivery: BackgroundDelivery? = nil) async throws -> AgentTaskHandle {
        guard var connection = connections[name] else {
            throw AgentRuntimeError.unknownAgent(name)
        }
        let delivery = delivery ?? defaultDelivery
        let delegationId = UUID().uuidString
        await observer?(.started(id: delegationId, agent: name, label: String(text.prefix(60))))

        let message = Message(
            messageId: MessageID(UUID().uuidString),
            role: .user,
            parts: [.text(text)],
            contextId: connection.contextId,
            taskId: nil
        )
        // push: タスク生成前にインライン config を載せ、ワーカーが実行前に登録 → 完了で能動通知（取りこぼし無し）。
        var configuration = SendMessageConfiguration(returnImmediately: true)
        if delivery.push {
            configuration.taskPushNotificationConfig = TaskPushNotificationConfig(url: "inprocess://delegation", token: delegationId)
            // sendMessage の await 中（追跡登録前）に届く push を取りこぼさないよう保留枠を先に開ける。
            pendingPushes[delegationId] = []
        }
        do {
            let response = try await connection.client.sendMessage(message, configuration: configuration)
            switch response {
            case .task(let task):
                if connection.contextId == nil {
                    connection.contextId = task.contextId
                    connections[name] = connection
                }
                delegatedTasks[task.id] = TrackedTask(agentName: name, delegationId: delegationId, snapshot: task, finished: false, monitors: [])
                lastAgent = name
                sessionActive = true
                // 有効な方式を**同時に**起動（すべて同じ observer イベントを finished-once で冪等に流す）。
                var monitors: [Task<Void, Never>] = []
                if delivery.subscribe {
                    monitors.append(Task { [weak self] in
                        guard let self else { return }
                        await self.monitorBackgroundTask(task.id)
                    })
                }
                if let interval = delivery.pollInterval {
                    monitors.append(Task { [weak self] in
                        guard let self else { return }
                        await self.pollBackgroundTask(task.id, interval: interval)
                    })
                }
                // push は監視ループ無し（ワーカーの InProcess push sender が ingestPush へ届ける）。
                delegatedTasks[task.id]?.monitors = monitors
                // 登録前に保留した push を順に流し直す（instant ワーカーの完了通知を復元）。
                for event in pendingPushes.removeValue(forKey: delegationId) ?? [] {
                    await deliverPush(event, taskId: task.id)
                }
                return AgentTaskHandle(name: name, taskId: task.id, contextId: task.contextId, state: task.status.state, immediateText: "")
            case .message(let agentMessage):
                pendingPushes[delegationId] = nil
                await observer?(.finished(id: delegationId, agent: name, text: agentMessage.text, state: nil))
                return AgentTaskHandle(name: name, taskId: nil, contextId: connection.contextId, state: nil, immediateText: agentMessage.text)
            }
        } catch {
            pendingPushes[delegationId] = nil
            await observer?(.failed(id: delegationId, agent: name, error: "\(error)"))
            throw error
        }
    }

    /// タスクの現在状態と成果物を取得（A2A `tasks/get`）。完了後も取得可能。LLM の check_task 用の読み取り専用クエリ。
    /// observer への進捗・完了通知は背景監視（`monitorBackgroundTask`）が担うため、ここでは発火しない。
    /// getTask がまだ永続化に追いつかない場合は即時スナップショットへフォールバック。
    public func checkTask(_ taskId: TaskID) async throws -> AgentTaskStatus {
        guard let tracked = delegatedTasks[taskId], let connection = connections[tracked.agentName] else {
            throw AgentRuntimeError.unknownAgent("task \(taskId.rawValue)")
        }
        let task = (try? await connection.client.getTask(taskId)) ?? tracked.snapshot
        delegatedTasks[taskId]?.snapshot = task
        return Self.status(of: task, agent: tracked.agentName)
    }

    // MARK: - 背景監視（subscribeToTask → observer）

    /// 背景委譲タスクを A2A `subscribeToTask`（resubscribe）で監視し、進捗・完了を observer へ流す。
    /// LLM の check_task 呼び出しに依存せず、ホストがターンを終えた後でも完了が UI に届く（fire-and-forget）。
    /// subscribe が使えない（既に終端=unsupportedOperation / queue 消失=taskNotFound / instant 完了）場合は
    /// getTask へフォールバックして最終状態を一度流す。
    private func monitorBackgroundTask(_ taskId: TaskID) async {
        guard let tracked = delegatedTasks[taskId], let connection = connections[tracked.agentName] else { return }
        let delegationId = tracked.delegationId
        let agent = tracked.agentName
        var streamed = false
        do {
            let stream = try await connection.client.subscribeToTask(taskId)
            for try await event in stream {
                streamed = true
                if case .task(let task) = event { delegatedTasks[taskId]?.snapshot = task }
                await observer?(.progress(id: delegationId, agent: agent, event))
                if let usage = Self.usage(of: event) {
                    await usageObserver?(delegationId, agent, usage)
                }
            }
        } catch is CancellationError {
            return // キャンセル時は session 側の cancel 経路が UI を更新する
        } catch {
            // subscribe 不可（終端済み/queue 消失）→ getTask で最終化
        }
        await finalizeBackgroundTask(taskId, alreadyStreamed: streamed)
    }

    /// 背景タスクの最終状態を getTask で確定し、`.finished` を一度だけ流す。
    private func finalizeBackgroundTask(_ taskId: TaskID, alreadyStreamed: Bool) async {
        guard let tracked = delegatedTasks[taskId], !tracked.finished,
              let connection = connections[tracked.agentName] else { return }
        // finished-once はここで**同期的に** claim する。getTask の await 中に push / poll が
        // 割り込むと `.finished` が二重発火するため（check と set の間に suspension を挟まない）。
        delegatedTasks[taskId]?.finished = true
        // queue の終了は「producer（executor）が返った」ことしか保証せず、終端状態の永続化
        //（TaskManager.process）はまだ追いついていないことがある。非終端のまま finalize すると
        // `.finished(state: .working)` を流して以後完了が永遠に届かなくなるため、
        // 終端/中断が引けるまで短い間隔で追いかける（producer は終了済みなので短時間で確定する。上限付き）。
        var task = (try? await connection.client.getTask(taskId)) ?? tracked.snapshot
        for _ in 0..<200 where !(task.status.state.isTerminal || task.status.state.isInterrupted) {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(10))
            if let refreshed = try? await connection.client.getTask(taskId) { task = refreshed }
        }
        delegatedTasks[taskId]?.snapshot = task
        let status = Self.status(of: task, agent: tracked.agentName)
        // subscribe が流れなかった場合のみ、最終 task を一度描画（成果物のパートを side-channel へ）。
        if !alreadyStreamed {
            await observer?(.progress(id: tracked.delegationId, agent: tracked.agentName, .task(task)))
            if let usage = status.usage {
                await usageObserver?(tracked.delegationId, tracked.agentName, usage)
            }
        }
        await observer?(.finished(id: tracked.delegationId, agent: tracked.agentName, text: status.text, state: task.status.state))
    }

    // MARK: - poll 配信（tasks/get を任意間隔で）

    /// 背景委譲タスクを `tasks/get` で interval ごとにポーリングし、進捗・完了を observer へ流す。
    private func pollBackgroundTask(_ taskId: TaskID, interval: Duration) async {
        guard let tracked = delegatedTasks[taskId], let connection = connections[tracked.agentName] else { return }
        let delegationId = tracked.delegationId
        let agent = tracked.agentName
        while !Task.isCancelled {
            do { try await Task.sleep(for: interval) } catch { return } // cancel
            guard let task = try? await connection.client.getTask(taskId) else { continue }
            delegatedTasks[taskId]?.snapshot = task
            await observer?(.progress(id: delegationId, agent: agent, .task(task)))
            if let usage = Self.usage(of: .task(task)) {
                await usageObserver?(delegationId, agent, usage)
            }
            if task.status.state.isTerminal || task.status.state.isInterrupted {
                if !(delegatedTasks[taskId]?.finished ?? true) {
                    delegatedTasks[taskId]?.finished = true
                    let status = Self.status(of: task, agent: agent)
                    await observer?(.finished(id: delegationId, agent: agent, text: status.text, state: task.status.state))
                }
                return
            }
        }
    }

    // MARK: - push 配信（ワーカーの InProcess sender → ここで受ける）

    /// ワーカーが push した `StreamResponse` を受け、token(delegationId) で委譲を解決して observer へ流す。
    private func ingestPush(_ event: StreamResponse, _ config: TaskPushNotificationConfig) async {
        guard let token = config.token else { return }
        guard let entry = delegatedTasks.first(where: { $0.value.delegationId == token }) else {
            // delegateAsync が追跡登録を終える前（sendMessage の await 中）に届いた push。
            // 保留枠があれば貯めておき、登録直後にドレインして配信する。
            if pendingPushes[token] != nil { pendingPushes[token]?.append(event) }
            return
        }
        await deliverPush(event, taskId: entry.key)
    }

    /// 解決済みタスクへの push イベント 1 件を observer へ配信し、終端なら finished-once を発火する。
    private func deliverPush(_ event: StreamResponse, taskId: TaskID) async {
        guard let tracked = delegatedTasks[taskId] else { return }
        if case .task(let task) = event { delegatedTasks[taskId]?.snapshot = task }
        await observer?(.progress(id: tracked.delegationId, agent: tracked.agentName, event))
        if let usage = Self.usage(of: event) {
            await usageObserver?(tracked.delegationId, tracked.agentName, usage)
        }
        if let state = Self.taskState(of: event), state.isTerminal || state.isInterrupted,
           !(delegatedTasks[taskId]?.finished ?? true) {
            delegatedTasks[taskId]?.finished = true
            let final = (try? await connections[tracked.agentName]?.client.getTask(taskId)) ?? tracked.snapshot
            let status = Self.status(of: final, agent: tracked.agentName)
            await observer?(.finished(id: tracked.delegationId, agent: tracked.agentName, text: status.text, state: final.status.state))
        }
    }

    /// 進行中（非終端）の委譲タスク一覧（A2A `tasks/get` で各タスクを refresh）。
    /// 終端タスクは一覧から除外するだけで追跡は保持する（後から `checkTask` で結果取得可能）。
    public func listRunningTasks() async -> [AgentTaskStatus] {
        var result: [AgentTaskStatus] = []
        for (taskId, tracked) in delegatedTasks { // 反復中の変異を避けるためキー集合を固定して走査
            guard let connection = connections[tracked.agentName] else { continue }
            let task = (try? await connection.client.getTask(taskId)) ?? tracked.snapshot
            if task.status.state.isTerminal { continue }
            result.append(Self.status(of: task, agent: tracked.agentName))
        }
        return result.sorted { $0.name < $1.name }
    }

    private static func status(of task: A2ATask, agent name: String) -> AgentTaskStatus {
        var pieces: [String] = []
        let artifactText = task.artifacts.map { $0.parts.compactMap(\.text).joined() }.joined(separator: "\n")
        if !artifactText.isEmpty { pieces.append(artifactText) }
        if task.status.state.isTerminal || task.status.state.isInterrupted,
           let statusMessage = task.status.message {
            let text = statusMessage.parts.compactMap(\.text).joined()
            if !text.isEmpty { pieces.append(text) }
        }
        let usage = task.artifacts.lazy.compactMap { UsageMetadata.decode($0.metadata) }.first
        return AgentTaskStatus(name: name, taskId: task.id, state: task.status.state, text: pieces.joined(separator: "\n"), usage: usage)
    }

    /// エージェントの進行中タスクを A2A `cancelTask` でキャンセル（best-effort）。
    /// 前景（`connection.taskId`）と背景委譲（`delegatedTasks`）の**両方**を止める。
    @discardableResult
    public func cancel(_ name: String) async -> TaskState? {
        guard let connection = connections[name] else { return nil }
        var lastState: TaskState?
        if let taskId = connection.taskId {
            lastState = try? await connection.client.cancelTask(taskId).status.state
        }
        // 同一エージェントの背景タスクを全てキャンセル（監視も全停止、並列委譲も取りこぼさない）。
        for (taskId, tracked) in delegatedTasks where tracked.agentName == name {
            tracked.monitors.forEach { $0.cancel() }
            if let state = try? await connection.client.cancelTask(taskId).status.state {
                lastState = state
            }
        }
        return lastState
    }

    /// 登録済み全エージェントの前景・背景タスクをキャンセルする（best-effort）。
    public func cancelAll() async {
        for name in connections.keys {
            _ = await cancel(name)
        }
    }
}
