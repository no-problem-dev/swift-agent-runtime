import A2ACore
import A2AClientCore
import A2AServer
import A2AInProcess
import LLMClient
import Foundation

/// A worker as the model sees it. The name and description go verbatim into the host's prompt and
/// into the roster tool, so they are what the model routes on — write them for a reader, not a log.
public struct AgentDescriptor: Sendable, Codable, Hashable {
    public let name: String
    public let description: String
}

/// What a blocking delegation produced.
public struct AgentSendOutcome: Sendable {
    public let name: String
    /// Artifacts, the terminal status message, and any direct message replies, joined by newlines.
    /// Intermediate progress notes are excluded.
    public let text: String
    /// The state the task ended in. `nil` means the worker replied with a message and opened no
    /// task at all. Note that a delegation returning normally does not mean it succeeded — a
    /// failed or cancelled worker also arrives here.
    public let state: TaskState?
    /// What the worker spent, if it reported anything.
    public let usage: TokenUsage?
}

/// The receipt for a delegation that was not waited on. The worker is still running.
///
/// Nothing on this handle reflects the eventual result; re-read the task, or watch the delegation
/// observer, to find out what happened.
public struct AgentTaskHandle: Sendable {
    public let name: String
    /// The task to follow up on, or `nil` if the worker answered immediately without opening one.
    public let taskId: TaskID?
    public let contextId: ContextID?
    /// The state at the instant the worker accepted the task — normally submitted or working, and
    /// stale by the time it is read.
    public let state: TaskState?
    /// The reply for a worker that finished without opening a task. Empty otherwise.
    public let immediateText: String
}

/// How the end of a background delegation gets noticed. The three mechanisms are layers, not
/// alternatives — turning several on is the point, because each fails differently.
///
/// Only the completion is deduplicated: whichever mechanism sees the terminal state first claims
/// it, and the others go quiet, so `finished` fires exactly once no matter how many are enabled.
/// Progress is *not* deduplicated, so with several on, the same update can be observed twice.
public struct BackgroundDelivery: Sendable, Equatable {
    /// Watch the worker's event stream. Gives live progress, and is the only one that does.
    public var subscribe: Bool
    /// Have the worker interrupt with a notification when it finishes. Catches the case where the
    /// stream was never established.
    public var push: Bool
    /// Re-read the task on this interval, or `nil` not to. This is the net under a worker that
    /// hangs or a stream that died silently, so a long gap is the point — polling faster buys
    /// nothing that subscribe and push do not already give.
    public var pollInterval: Duration?

    public init(subscribe: Bool = true, push: Bool = true, pollInterval: Duration? = .seconds(120)) {
        self.subscribe = subscribe
        self.push = push
        self.pollInterval = pollInterval
    }

    /// All three, polling every two minutes. The default, and the most robust.
    public static let all = BackgroundDelivery()
    public static let subscribeOnly = BackgroundDelivery(subscribe: true, push: false, pollInterval: nil)
    public static let pushOnly = BackgroundDelivery(subscribe: false, push: true, pollInterval: nil)
    public static func pollOnly(every: Duration) -> BackgroundDelivery {
        BackgroundDelivery(subscribe: false, push: false, pollInterval: every)
    }
}

/// Whether a reading actually came from the worker, or is the last one that got through.
///
/// This is what separates "the task has not moved" from "we could not ask" — two situations that
/// otherwise produce the same `AgentTaskStatus` and lead a caller to act on state it never read.
public enum TaskReadingFreshness: Sendable, Equatable {
    /// Re-read from the worker for this call.
    case fresh
    /// The re-read failed. The accompanying state and text are the last ones that did get through,
    /// and the task may have moved on since — including to a terminal state. `reason` is the
    /// transport failure, stringified.
    case stale(reason: String)
}

/// A point-in-time reading of a delegated task.
public struct AgentTaskStatus: Sendable {
    public let name: String
    public let taskId: TaskID
    /// The state as of this reading. A non-terminal value can be stale by the time it is used.
    public let state: TaskState
    /// Artifacts plus the status message, but only once the task is terminal or waiting on input —
    /// mid-flight progress notes are left out. Empty while the worker is still working.
    public let text: String
    /// What the worker reported spending, or `nil` if it recorded none.
    public let usage: TokenUsage?
    /// Where this reading came from. Anything other than `.fresh` means the fields above describe
    /// an earlier moment, not now.
    public let freshness: TaskReadingFreshness
}

/// What asking a worker to stop actually achieved.
///
/// Cancelling is best-effort, which used to make "there was nothing to cancel" and "the cancel
/// request never got through" the same answer. They are separated here because only one of them
/// means work may still be running.
public struct CancellationOutcome: Sendable {
    /// The last state seen while cancelling, or `nil` if nothing was cancelled.
    public let lastState: TaskState?
    /// The failures met along the way, stringified. Empty when every request got through — a task
    /// the agent reports as already finished or unknown is not one of these, because there was
    /// nothing left to stop.
    public let failures: [String]
    /// Whether at least one cancel request failed, so a worker may still be running.
    public var didFail: Bool { !failures.isEmpty }
}

/// Holds one connection per worker and delegates over it.
///
/// The connection is an injected client, so in-process and remote workers are handled the same
/// way. Each connection remembers its task and context ids, which is what makes a follow-up
/// message resume the worker's existing conversation rather than start a new one — with the
/// consequence that two sequential blocking delegations to the same worker share a task, while
/// background delegations always get fresh ones.
///
/// The actor also tracks which worker was delegated to last and whether that exchange is still
/// open, and feeds both into the host's prompt.
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
    private let usageObserver: DelegationUsageObserver?
    /// Used by background delegations that do not name their own delivery.
    private let defaultDelivery: BackgroundDelivery

    private var lastAgent: String?
    /// Whether the last exchange is still open. False once it reaches a terminal state; an
    /// interrupted worker waiting on input still counts as open.
    private var sessionActive = false

    /// Builds the push sender a worker needs for push delivery to work.
    ///
    /// Registering a worker by executor wires this up already. Registering a pre-built client or
    /// handler does not, so pass this to the handler yourself — without it, push delivery is
    /// silently inert and completion only arrives via subscribe or polling.
    public func makePushSender() -> InProcessPushNotificationSender {
        InProcessPushNotificationSender { [weak self] event, config in
            await self?.ingestPush(event, config)
        }
    }

    private struct TrackedTask {
        let agentName: String
        /// Identifies this delegation to observers, so parallel work stays in separate lanes.
        let delegationId: String
        var snapshot: A2ATask
        /// Set once, by whichever delivery mechanism sees the terminal state first. Guards the
        /// single completion notification.
        var finished: Bool
        /// The subscribe and poll loops. Cancelled together when the delegation is cancelled.
        /// Push has no loop, so it is not represented here.
        var monitors: [Task<Void, Never>]
        /// Set when the task was seen in a terminal state: its monitors are gone and it is now
        /// only kept so its result can still be read.
        var retired: Bool
    }
    // Background delegations, keyed by task. Entries survive completion so a result can still be
    // fetched afterwards, but only the most recent `retainedFinishedTasks` of them — a host that
    // runs for a long time would otherwise hold every task snapshot it ever delegated.
    // The snapshot is the worker's immediate response, kept as a fallback for the window where
    // re-reading the task would 404 because persistence has not caught up yet.
    private var delegatedTasks: [TaskID: TrackedTask] = [:]
    /// Finished delegations in the order they finished, oldest first. Only these are ever dropped;
    /// a task still running is never evicted, however many of them there are.
    private var retiredTasks: [TaskID] = []
    private let retainedFinishedTasks: Int
    // Push notifications that arrived before the delegation finished registering itself. A worker
    // that completes instantly can push before the send call has even returned; without this
    // holding area those notifications would be dropped and push-only delivery would never fire.
    private var pendingPushes: [String: [StreamResponse]] = [:]

    /// The worker the host is mid-conversation with, or `"None"`. Goes into the host's prompt.
    public var activeAgent: String { sessionActive ? (lastAgent ?? "None") : "None" }

    /// How many finished delegations stay readable when nothing else is said.
    ///
    /// Wide enough that a turn which fans out and then collects its results never loses one, and
    /// narrow enough that a host running all day does not hold every task it ever delegated.
    public static var defaultRetainedFinishedTasks: Int { 64 }

    /// - Parameters:
    ///   - retainedFinishedTasks: How many finished delegations stay readable by task id. Once
    ///     more than this have finished, the oldest are dropped and `checkTask` no longer knows
    ///     them. Running delegations are never dropped. Values below one are treated as one.
    public init(
        mode: DeliveryMode = .streaming,
        observer: DelegationObserver? = nil,
        usageObserver: DelegationUsageObserver? = nil,
        defaultDelivery: BackgroundDelivery = .all,
        retainedFinishedTasks: Int = AgentConnectionRegistry.defaultRetainedFinishedTasks
    ) {
        self.mode = mode
        self.observer = observer
        self.usageObserver = usageObserver
        self.defaultDelivery = defaultDelivery
        self.retainedFinishedTasks = max(1, retainedFinishedTasks)
    }

    /// Registers a worker reached through an existing client, typically a remote one.
    /// Registering the same name twice replaces the connection and loses its conversation state.
    /// Push delivery will not work unless the client's handler was built with `makePushSender`.
    public func register(card: AgentCard, client: A2AClient) {
        connections[card.name] = Connection(card: card, client: client)
    }

    /// Registers a worker served by a handler in this process. Same push caveat as above.
    public func register(card: AgentCard, handler: any RequestHandler) {
        register(card: card, client: A2AClient.inProcess(handler: handler))
    }

    /// Registers an in-process worker, wiring up its push store and sender so push delivery works.
    /// Prefer this over the handler and client overloads unless a handler is already built.
    public func register(card: AgentCard, executor: any AgentExecutor) {
        let handler = DefaultRequestHandler(
            agentCard: card, executor: executor,
            pushConfigStore: InMemoryPushNotificationConfigStore(),
            pushSender: makePushSender()
        )
        register(card: card, handler: handler)
    }

    /// The registered workers, sorted by name so the model sees a stable order across turns.
    public func descriptors() -> [AgentDescriptor] {
        connections.values
            .map { AgentDescriptor(name: $0.card.name, description: $0.card.description) }
            .sorted { $0.name < $1.name }
    }

    /// The roster as one JSON object per line, ready to drop into the host's prompt.
    /// Empty when nothing is registered, which is how the host detects an empty fleet.
    public func rosterJSONLines() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return descriptors().compactMap { descriptor in
            (try? encoder.encode(descriptor)).flatMap { String(data: $0, encoding: .utf8) }
        }.joined(separator: "\n")
    }

    /// Sends a message to a worker and waits for it to finish.
    ///
    /// The connection's stored task and context ids are reused, so this continues the worker's
    /// existing conversation — that is what lets a worker paused on a question be answered by
    /// sending again. It also means two concurrent calls to the same worker collide on one task;
    /// use a background delegation for parallel work.
    ///
    /// Progress reaches the observer while the call is still blocked. A worker that fails or is
    /// cancelled returns normally with that state — only a transport error throws.
    ///
    /// - Throws: `AgentRuntimeError.unknownAgent` if no worker is registered under `name`, or
    ///   whatever the transport threw.
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
        // Only the status message from a terminal or interrupted event is kept — that is where a
        // question to the user lives. Mid-flight progress notes are dropped.
        var finalStatusMessage = ""
        var finalState: TaskState?
        var usage: TokenUsage?

        do {
            for try await event in connection.client.events(message, mode: mode) {
                await observer?(.progress(id: delegationId, agent: name, response: event))
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
        // A terminal state closes the exchange; an interruption waiting on input keeps it open,
        // so the next message resumes the same task instead of starting a new one.
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

    /// Delegates without flattening anything: structured parts and metadata go to the worker as
    /// they are, and its events come back raw.
    ///
    /// Use this when the payload is not text — the blocking form joins everything into a string,
    /// which destroys structured parts. Conversation state and observer notifications work the
    /// same as there.
    ///
    /// Throws immediately for an unknown worker; transport failures surface on the stream.
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
                        await observer?(.progress(id: delegationId, agent: name, response: event))
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

    /// The one place a tracked task's snapshot is written.
    ///
    /// Funnelling every write through here is what makes reaching a terminal state a single event
    /// the registry can act on, however it was noticed — subscribe, poll, push or a direct read.
    private func updateSnapshot(_ task: A2ATask, for taskId: TaskID) {
        guard delegatedTasks[taskId] != nil else { return }
        delegatedTasks[taskId]?.snapshot = task
        if task.status.state.isTerminal { retire(taskId) }
    }

    /// Winds a finished delegation down: its monitors are torn down, and it joins the queue of
    /// results kept for reading, from which the oldest are dropped once the queue is full.
    ///
    /// Tearing the monitors down here is the point of doing this at all — a poll loop sleeping on
    /// a long interval would otherwise keep the delegation, and its snapshot, alive well past the
    /// work being over.
    private func retire(_ taskId: TaskID) {
        guard var tracked = delegatedTasks[taskId], !tracked.retired else { return }
        tracked.monitors.forEach { $0.cancel() }
        tracked.monitors = []
        tracked.retired = true
        delegatedTasks[taskId] = tracked
        retiredTasks.append(taskId)
        while retiredTasks.count > retainedFinishedTasks {
            let oldest = retiredTasks.removeFirst()
            delegatedTasks.removeValue(forKey: oldest)
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
        // Same rule as the blocking path: terminal closes the exchange, interrupted keeps it open.
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

    // MARK: - Background delegation

    /// Starts a worker and returns as soon as it has accepted the task, without waiting for it.
    ///
    /// This is how several workers run at once: each call opens a fresh task with no task id, so
    /// concurrent delegations to the same worker do not collide the way blocking ones do. The
    /// worker keeps running after this returns and after the host's turn ends. Read the result
    /// later, or watch for it on the delegation observer.
    ///
    /// The task stays readable after it completes, but only while it is among the most recent
    /// `retainedFinishedTasks` to have finished — past that it is dropped and `checkTask` no
    /// longer knows it. A task still running is never dropped.
    ///
    /// - Parameters:
    ///   - name: The registered worker.
    ///   - text: The instruction.
    ///   - delivery: How completion is noticed. `nil` uses the registry's default.
    /// - Throws: `AgentRuntimeError.unknownAgent`, or whatever the transport threw while starting.
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
        // The push config rides in with the request itself, so the worker has it registered before
        // it starts working and no completion can slip through the gap.
        var configuration = SendMessageConfiguration(returnImmediately: true)
        if delivery.push {
            configuration.taskPushNotificationConfig = TaskPushNotificationConfig(url: "inprocess://delegation", token: delegationId)
            // Open the holding area first: a push can land during the suspension below, before
            // this delegation is tracked at all.
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
                delegatedTasks[task.id] = TrackedTask(agentName: name, delegationId: delegationId, snapshot: task, finished: false, monitors: [], retired: false)
                lastAgent = name
                sessionActive = true
                // Start every enabled mechanism at once; the finished-once guard keeps them from
                // reporting completion more than one time between them.
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
                // Push needs no loop — the worker's sender delivers straight into this actor.
                delegatedTasks[task.id]?.monitors = monitors
                // Replay anything that arrived while this delegation was still being set up.
                for event in pendingPushes.removeValue(forKey: delegationId) ?? [] {
                    await deliverPush(event, taskId: task.id)
                }
                return AgentTaskHandle(name: name, taskId: task.id, contextId: task.contextId, state: task.status.state, immediateText: "")
            case .message(let agentMessage):
                // The worker answered outright; there is nothing to track or follow up on.
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

    /// Re-reads a background task. Works after it has completed, which is how a result is fetched.
    ///
    /// Read-only and silent: nothing is reported to observers here, because the background
    /// monitors already do that. Calling it repeatedly is safe and has no side effects beyond
    /// refreshing the cached snapshot.
    ///
    /// A re-read that fails still returns the last known snapshot — that covers the window before
    /// the worker's state is persisted — but the result says so on `freshness`, so a transport
    /// failure is never handed back as a fresh reading.
    ///
    /// - Throws: `AgentRuntimeError.unknownAgent` if this task was never delegated from here, or
    ///   if it was delegated so long ago that it has been dropped from the finished-task history.
    public func checkTask(_ taskId: TaskID) async throws -> AgentTaskStatus {
        guard let tracked = delegatedTasks[taskId], let connection = connections[tracked.agentName] else {
            throw AgentRuntimeError.unknownAgent("task \(taskId.rawValue)")
        }
        do {
            let task = try await connection.client.getTask(taskId)
            updateSnapshot(task, for: taskId)
            return Self.status(of: task, agent: tracked.agentName, freshness: .fresh)
        } catch {
            return Self.status(of: tracked.snapshot, agent: tracked.agentName, freshness: .stale(reason: "\(error)"))
        }
    }

    // MARK: - Subscribe delivery

    /// Watches a background task's event stream and reports progress and completion.
    ///
    /// This is what makes completion reach the UI without the model ever asking for it, including
    /// after the host's turn has ended. When subscribing is impossible — the task already ended,
    /// its queue is gone, or it finished before this started — it falls back to re-reading the
    /// task once and reporting the final state from there.
    private func monitorBackgroundTask(_ taskId: TaskID) async {
        guard let tracked = delegatedTasks[taskId], let connection = connections[tracked.agentName] else { return }
        let delegationId = tracked.delegationId
        let agent = tracked.agentName
        var streamed = false
        do {
            let stream = try await connection.client.subscribeToTask(taskId)
            for try await event in stream {
                streamed = true
                if case .task(let task) = event { updateSnapshot(task, for: taskId) }
                await observer?(.progress(id: delegationId, agent: agent, response: event))
                if let usage = Self.usage(of: event) {
                    await usageObserver?(delegationId, agent, usage)
                }
            }
        } catch is CancellationError {
            return // The cancel path updates the UI; reporting a completion here would fight it.
        } catch {
            // Subscribing failed. Fall through and settle the task by re-reading it.
        }
        await finalizeBackgroundTask(taskId, alreadyStreamed: streamed)
    }

    /// Settles a background task's final state and reports completion, at most once.
    private func finalizeBackgroundTask(_ taskId: TaskID, alreadyStreamed: Bool) async {
        guard let tracked = delegatedTasks[taskId], !tracked.finished,
              let connection = connections[tracked.agentName] else { return }
        // Claim the completion synchronously, with no suspension between the check above and this
        // write: awaiting first would let push or poll slip in and report completion twice.
        delegatedTasks[taskId]?.finished = true
        // The stream ending only means the worker's function returned — its terminal state may not
        // be persisted yet. Reporting a non-terminal state here would be permanent, since the
        // claim above stops anyone else from correcting it, so chase the real state at a short
        // interval. Bounded at roughly two seconds; past that it reports whatever it has.
        var task = tracked.snapshot
        var readFailure: String?
        var everRead = false
        for attempt in 0..<200 {
            if attempt > 0 {
                if Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            do {
                task = try await connection.client.getTask(taskId)
                everRead = true
                readFailure = nil
            } catch {
                readFailure = "\(error)"
            }
            if task.status.state.isTerminal || task.status.state.isInterrupted { break }
        }
        // Push or poll may have brought back a settled snapshot while this was chasing, in which
        // case the chase failing to read anything is not the whole story.
        if !everRead, let stored = delegatedTasks[taskId]?.snapshot,
           stored.status.state.isTerminal || stored.status.state.isInterrupted {
            task = stored
        }
        updateSnapshot(task, for: taskId)
        // Every read failed, so the only state on hand is the one from before the work started.
        // Announcing that as the finish would be a completion nobody observed; the delegation
        // failed to settle, and that is what the observer is told.
        guard everRead || task.status.state.isTerminal || task.status.state.isInterrupted else {
            await observer?(.failed(
                id: tracked.delegationId, agent: tracked.agentName,
                error: "could not read the task's final state: \(readFailure ?? "unknown error")"
            ))
            return
        }
        let status = Self.status(of: task, agent: tracked.agentName, freshness: .fresh)
        // If the stream produced nothing, the observer has never seen this task's output, so send
        // the final task through once. Skipped otherwise to avoid showing it twice.
        if !alreadyStreamed {
            await observer?(.progress(id: tracked.delegationId, agent: tracked.agentName, response: .task(task)))
            if let usage = status.usage {
                await usageObserver?(tracked.delegationId, tracked.agentName, usage)
            }
        }
        await observer?(.finished(id: tracked.delegationId, agent: tracked.agentName, text: status.text, state: task.status.state))
    }

    // MARK: - Poll delivery

    /// Re-reads a background task on an interval until it is terminal, reporting what it sees.
    /// Runs for as long as the task does — a worker that never terminates keeps this polling.
    private func pollBackgroundTask(_ taskId: TaskID, interval: Duration) async {
        guard let tracked = delegatedTasks[taskId], let connection = connections[tracked.agentName] else { return }
        let delegationId = tracked.delegationId
        let agent = tracked.agentName
        while !Task.isCancelled {
            do { try await Task.sleep(for: interval) } catch { return } // cancelled
            // A failed read is treated as "try again next interval", not as an error.
            guard let task = try? await connection.client.getTask(taskId) else { continue }
            updateSnapshot(task, for: taskId)
            await observer?(.progress(id: delegationId, agent: agent, response: .task(task)))
            if let usage = Self.usage(of: .task(task)) {
                await usageObserver?(delegationId, agent, usage)
            }
            if task.status.state.isTerminal || task.status.state.isInterrupted {
                if !(delegatedTasks[taskId]?.finished ?? true) {
                    delegatedTasks[taskId]?.finished = true
                    let status = Self.status(of: task, agent: agent, freshness: .fresh)
                    await observer?(.finished(id: delegationId, agent: agent, text: status.text, state: task.status.state))
                }
                return
            }
        }
    }

    // MARK: - Push delivery

    /// Receives a worker's push notification and matches it to a delegation by its token.
    /// A notification with no token, or one for an unknown delegation with no holding area, is
    /// dropped without a trace.
    private func ingestPush(_ event: StreamResponse, _ config: TaskPushNotificationConfig) async {
        guard let token = config.token else { return }
        guard let entry = delegatedTasks.first(where: { $0.value.delegationId == token }) else {
            // Arrived before the delegation finished registering itself. Hold it if a slot is
            // open; it will be replayed as soon as tracking is in place.
            if pendingPushes[token] != nil { pendingPushes[token]?.append(event) }
            return
        }
        await deliverPush(event, taskId: entry.key)
    }

    /// Reports one push notification, claiming the completion if it carries a terminal state.
    private func deliverPush(_ event: StreamResponse, taskId: TaskID) async {
        guard let tracked = delegatedTasks[taskId] else { return }
        if case .task(let task) = event { updateSnapshot(task, for: taskId) }
        await observer?(.progress(id: tracked.delegationId, agent: tracked.agentName, response: event))
        if let usage = Self.usage(of: event) {
            await usageObserver?(tracked.delegationId, tracked.agentName, usage)
        }
        if let state = Self.taskState(of: event), state.isTerminal || state.isInterrupted,
           !(delegatedTasks[taskId]?.finished ?? true) {
            delegatedTasks[taskId]?.finished = true
            // The push already carried the terminal state; re-reading only enriches it with the
            // artifacts. A re-read that fails must not walk the state back to the older snapshot,
            // so the pushed task — and failing that, the pushed state — wins over it.
            var final = tracked.snapshot
            if case .task(let pushed) = event { final = pushed }
            if let refreshed = try? await connections[tracked.agentName]?.client.getTask(taskId) { final = refreshed }
            updateSnapshot(final, for: taskId)
            let status = Self.status(of: final, agent: tracked.agentName, freshness: .fresh)
            let reported = (final.status.state.isTerminal || final.status.state.isInterrupted) ? final.status.state : state
            await observer?(.finished(id: tracked.delegationId, agent: tracked.agentName, text: status.text, state: reported))
        }
    }

    /// The background tasks still in flight, each re-read before being reported.
    ///
    /// Finished tasks drop out of this list but stay tracked while they are among the most recent
    /// `retainedFinishedTasks`, so their results remain fetchable until then.
    /// Cost grows with the number of tracked tasks, since every one is re-read on each call.
    ///
    /// A task whose re-read failed is still listed — it cannot be ruled out as running — and says
    /// so on `freshness`, so an unreachable worker is not mistaken for a working one.
    public func listRunningTasks() async -> [AgentTaskStatus] {
        var result: [AgentTaskStatus] = []
        for (taskId, tracked) in delegatedTasks { // Iterate a fixed snapshot; the body suspends.
            guard let connection = connections[tracked.agentName] else { continue }
            do {
                let task = try await connection.client.getTask(taskId)
                updateSnapshot(task, for: taskId)
                if task.status.state.isTerminal { continue }
                result.append(Self.status(of: task, agent: tracked.agentName, freshness: .fresh))
            } catch {
                if tracked.snapshot.status.state.isTerminal { continue }
                result.append(Self.status(of: tracked.snapshot, agent: tracked.agentName, freshness: .stale(reason: "\(error)")))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    private static func status(of task: A2ATask, agent name: String, freshness: TaskReadingFreshness) -> AgentTaskStatus {
        var pieces: [String] = []
        let artifactText = task.artifacts.map { $0.parts.compactMap(\.text).joined() }.joined(separator: "\n")
        if !artifactText.isEmpty { pieces.append(artifactText) }
        if task.status.state.isTerminal || task.status.state.isInterrupted,
           let statusMessage = task.status.message {
            let text = statusMessage.parts.compactMap(\.text).joined()
            if !text.isEmpty { pieces.append(text) }
        }
        let usage = task.artifacts.lazy.compactMap { UsageMetadata.decode($0.metadata) }.first
        return AgentTaskStatus(
            name: name, taskId: task.id, state: task.status.state,
            text: pieces.joined(separator: "\n"), usage: usage, freshness: freshness
        )
    }

    /// Asks a worker to stop everything it is doing for this registry, foreground and background.
    ///
    /// Best-effort: a worker that has already finished, or that ignores cancellation, produces no
    /// error here. Monitor loops for that worker's background tasks are torn down regardless.
    ///
    /// A cancel request that could not be delivered is reported on the outcome rather than
    /// swallowed, so "there was nothing to stop" and "the worker may still be running" stay apart.
    /// Cancelling twice is safe.
    @discardableResult
    public func cancel(_ name: String) async -> CancellationOutcome {
        guard let connection = connections[name] else { return CancellationOutcome(lastState: nil, failures: []) }
        // Tear the monitors down and collect the work to stop before suspending, so the bookkeeping
        // is settled whatever the requests below do.
        var taskIds: [TaskID] = []
        if let taskId = connection.taskId { taskIds.append(taskId) }
        // Every background task for this worker, not just the newest: parallel delegations would
        // otherwise keep running with their monitors torn down.
        for (taskId, tracked) in delegatedTasks where tracked.agentName == name {
            tracked.monitors.forEach { $0.cancel() }
            delegatedTasks[taskId]?.monitors = []
            taskIds.append(taskId)
        }

        var lastState: TaskState?
        var failures: [String] = []
        for taskId in taskIds {
            do { lastState = try await connection.client.cancelTask(taskId).status.state }
            catch {
                // A task the agent says is finished or unknown has nothing left to stop, which is
                // the ordinary outcome of cancelling twice — not a request that failed to arrive.
                guard !Self.meansNothingToCancel(error) else { continue }
                failures.append("\(name)/\(taskId.rawValue): \(error)")
            }
        }
        return CancellationOutcome(lastState: lastState, failures: failures)
    }

    /// Whether a failed cancel means the work was already over rather than out of reach.
    private static func meansNothingToCancel(_ error: any Error) -> Bool {
        guard case .rpc(let remote) = error as? A2AError else { return false }
        return remote.code == A2ARemoteError.taskNotCancelable || remote.code == A2ARemoteError.taskNotFound
    }

    /// Cancels every registered worker, one after another. Best-effort and safe to repeat.
    ///
    /// - Returns: Every cancel request that failed, across all workers. Empty when they all got
    ///   through. A non-empty result means some worker may still be running.
    @discardableResult
    public func cancelAll() async -> [String] {
        var failures: [String] = []
        for name in connections.keys {
            failures.append(contentsOf: await cancel(name).failures)
        }
        return failures
    }
}
