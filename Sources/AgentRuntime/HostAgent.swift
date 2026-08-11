import AgentLoopKit
import A2ACore
import LLMClient
import LLMTool
import LLMAgentStep
import Foundation

/// Raised by the host's own turn handling.
public enum HostAgentError: Error, Sendable, Equatable {
    /// A turn was started while another was still in flight. The host owns one conversation, so a
    /// second concurrent turn would interleave into the same history and produce a transcript
    /// neither caller asked for. Wait for the turn to finish, or `cancel()` it first.
    case turnAlreadyRunning
}

/// An agent whose job is to hand work to other agents and compose their answers.
///
/// The host is itself a model in a tool loop; its tools are the delegation tools, and its prompt
/// is assembled from the registry's roster. Registering no workers turns delegation off entirely
/// — both the tools and the delegating wording disappear — so an empty fleet degrades into a
/// plain assistant rather than a confused delegator.
///
/// Conversation history is kept across every `run` and `stream` on the same instance, including
/// the tool calls and their results, so a follow-up can be answered from context without
/// delegating again. Call `clear()` to start over.
///
/// One turn runs at a time. A `run` or `stream` started while another turn is in flight is
/// refused with `HostAgentError.turnAlreadyRunning` rather than joining it, which is what keeps
/// the history a single conversation and keeps `cancel()` unambiguous about what it stops.
public actor HostAgent<Client: AgentCapableClient> where Client.Model: Sendable {
    private let client: Client
    private let model: Client.Model
    private let registry: AgentConnectionRegistry
    private let extraTools: ToolSet
    private let outputInstruction: String?
    private let maxSteps: Int
    private let maxTokens: Int?
    private let outputValidator: (@Sendable (String) -> [String])?
    private let correctivePrompt: (@Sendable (_ issues: [String], _ originalInput: String) -> String)?
    private let maxValidationRetries: Int
    private let cachePolicy: PromptCachePolicy
    private var history: [LLMMessage] = []

    /// The turn in flight, if there is one. Identified so that a turn only ever clears its own
    /// registration — a finishing turn must not deregister the one that came after it.
    private struct ActiveTurn {
        let id: UUID
        let cancel: @Sendable () -> Void
    }
    private var activeTurn: ActiveTurn?

    /// Creates a host bound to one client, model and worker registry.
    ///
    /// - Parameters:
    ///   - client: The LLM client the host itself runs on.
    ///   - model: The model identifier for the host's own reasoning.
    ///   - registry: The workers this host may delegate to. Read fresh on every turn, so workers
    ///     registered later become available without rebuilding the host. An empty registry
    ///     suppresses both the delegation tools and the delegating prompt.
    ///   - outputInstruction: Appended after the delegation prompt as its own section, for output
    ///     format rules. The delegation wording itself is never altered.
    ///   - extraTools: Tools beyond delegation. Merged with the delegation tools, so a name
    ///     colliding with one of those is a problem to avoid.
    ///   - maxSteps: Step budget for one turn. Exhausting it returns empty text, not an error.
    ///   - maxTokens: Output token ceiling per step. `nil` uses the model's default.
    ///   - outputValidator: Inspects the final text and returns the problems with it, or an empty
    ///     array if it is fine. Keeps domain rules out of the runtime. `nil` skips validation.
    ///   - correctivePrompt: Builds the retry prompt from the problems and the original request.
    ///     `nil` uses a generic English one.
    ///   - maxValidationRetries: Retries after a failed validation, excluding the first attempt —
    ///     `0` means one attempt total. Each retry is a full extra turn, billed as such. When the
    ///     retries run out the invalid text is returned anyway.
    ///   - cachePolicy: Prompt caching for the stable prefix. Applied to every step.
    public init(
        client: Client,
        model: Client.Model,
        registry: AgentConnectionRegistry,
        outputInstruction: String? = nil,
        extraTools: ToolSet = ToolSet {},
        maxSteps: Int = 12,
        maxTokens: Int? = nil,
        outputValidator: (@Sendable (String) -> [String])? = nil,
        correctivePrompt: (@Sendable (_ issues: [String], _ originalInput: String) -> String)? = nil,
        maxValidationRetries: Int = 0,
        cachePolicy: PromptCachePolicy = .implicit
    ) {
        self.client = client
        self.model = model
        self.registry = registry
        self.outputInstruction = outputInstruction
        self.extraTools = extraTools
        self.maxSteps = maxSteps
        self.maxTokens = maxTokens
        self.outputValidator = outputValidator
        self.correctivePrompt = correctivePrompt
        self.maxValidationRetries = maxValidationRetries
        self.cachePolicy = cachePolicy
    }

    /// The whole conversation so far, tool calls and results included. Persist this to resume the
    /// host later; it grows with every turn and nothing trims it.
    public var messages: [LLMMessage] { history }

    /// Forgets the conversation. The next turn starts fresh.
    public func clear() {
        history.removeAll()
    }

    /// Replaces the conversation wholesale, to resume a persisted session.
    /// Call before the first turn — doing it mid-conversation discards what has happened.
    public func loadHistory(_ messages: [LLMMessage]) {
        history = messages
    }

    /// Whether a turn is in flight. Starting another one while this is `true` is refused.
    public var isRunningTurn: Bool { activeTurn != nil }

    /// Runs one turn from a text prompt and returns the final answer.
    public func run(_ userInput: String) async throws -> String {
        try await run(.user(userInput))
    }

    /// Runs one turn from a prompt that may carry attachments.
    ///
    /// Cancelling the calling task cancels the turn and, through the structured tree, the workers
    /// it delegated to. The history is only updated when the turn completes, so a cancelled turn
    /// leaves the conversation as it was.
    ///
    /// - Throws: `HostAgentError.turnAlreadyRunning` if a turn is already in flight, on top of
    ///   whatever the turn itself throws.
    public func run(_ userMessage: LLMMessage) async throws -> String {
        // Claimed before the first suspension point, so two callers cannot both get through.
        guard activeTurn == nil else { throw HostAgentError.turnAlreadyRunning }
        let id = UUID()
        let task = Task { try await self.runInner(userMessage) }
        activeTurn = ActiveTurn(id: id, cancel: { task.cancel() })
        defer { endTurn(id) }
        // Bridge the caller's cancellation into the retained task, so cancelling from outside and
        // calling cancel() take the same path.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Releases the registration for one turn, and only that turn.
    private func endTurn(_ id: UUID) {
        if activeTurn?.id == id { activeTurn = nil }
    }

    /// Stops the turn in progress and asks every worker to stop too.
    ///
    /// Cancels the running turn, which propagates down the structured tree, and separately
    /// cancels each worker's task so background delegations that outlive the turn also stop.
    /// Reaches the turn whichever way it was started, `run` or `stream`, because only one runs at
    /// a time. Safe to call when nothing is running.
    public func cancel() async {
        activeTurn?.cancel()
        await registry.cancelAll()
    }

    /// Releases server-side prompt caches held by the client, where the provider bills for them.
    /// Does nothing for clients without that concept. Call when a session ends.
    public func close() async {
        if let releasing = client as? PromptCacheReleasing {
            await releasing.releasePromptCaches()
        }
    }

    private func runInner(_ userMessage: LLMMessage) async throws -> String {
        // The whole transcript becomes the history, delegation calls and their results included —
        // that is what lets the next turn answer "what did you just find out" without delegating
        // again. A validator, if present, drives regenerate-and-recheck rounds on top of that.
        let originalText = Self.text(of: userMessage)
        var input = userMessage
        var attempt = 0
        var finalText = ""
        while true {
            let loop = await makeLoop()
            history = try await loop.run(messages: history + [input]) { event in
                if case .completed(let text) = event { finalText = text }
            }
            guard let validator = outputValidator else { return finalText }
            let issues = validator(finalText)
            if issues.isEmpty || attempt >= maxValidationRetries { return finalText }
            attempt += 1
            input = .user((correctivePrompt ?? Self.defaultCorrectivePrompt)(issues, originalText))
        }
    }

    /// Runs one turn from a text prompt, delivering events as they happen.
    public func stream(_ userInput: String, telemetry: AgentTelemetrySink? = nil) -> AsyncThrowingStream<AgentLoop<Client>.Event, Error> {
        stream(.user(userInput), telemetry: telemetry)
    }

    /// Runs one turn from a prompt that may carry attachments, delivering events as they happen.
    ///
    /// The turn runs in an unstructured task, stopped either by terminating the stream or by
    /// `cancel()` — it is the same turn to both. Starting this while another turn is in flight
    /// fails the stream with `HostAgentError.turnAlreadyRunning` instead of running alongside it.
    /// With a validator configured, a rejected answer is regenerated, which means a consumer can
    /// see two `completed` events in one turn; watch the telemetry sink to tell "this is being
    /// replaced" from "this is final".
    public func stream(_ userMessage: LLMMessage, telemetry: AgentTelemetrySink? = nil) -> AsyncThrowingStream<AgentLoop<Client>.Event, Error> {
        AsyncThrowingStream { continuation in
            guard activeTurn == nil else {
                continuation.finish(throwing: HostAgentError.turnAlreadyRunning)
                return
            }
            let id = UUID()
            let task = Task {
                defer { self.endTurn(id) }
                do {
                    // Each generation is validated, and a rejected one is retried by sending the
                    // corrective prompt as a new user turn — so the failed attempt stays in the
                    // history rather than being rewritten. Failures are reported on telemetry so
                    // a consumer can decide between redrawing and falling back.
                    let originalText = Self.text(of: userMessage)
                    var input = userMessage
                    var attempt = 0
                    while true {
                        let loop = await self.makeLoop(telemetry: telemetry)
                        let prior = self.history
                        var finalText = ""
                        let transcript = try await loop.run(messages: prior + [input]) { event in
                            if case .completed(let text) = event { finalText = text }
                            continuation.yield(event)
                        }
                        self.setHistory(transcript)

                        guard let validator = self.outputValidator else { break }
                        let issues = validator(finalText)
                        if issues.isEmpty { break }
                        let willRetry = attempt < self.maxValidationRetries
                        await telemetry?(.validationFailed(issues: issues, willRetry: willRetry))
                        if !willRetry { break }
                        attempt += 1
                        let builder = self.correctivePrompt ?? Self.defaultCorrectivePrompt
                        input = .user(builder(issues, originalText))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            activeTurn = ActiveTurn(id: id, cancel: { task.cancel() })
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Joins a message's text for the corrective prompt. Attachments are lost, so a retry sees
    /// only the words of the original request.
    private static func text(of message: LLMMessage) -> String {
        message.contents.compactMap { content -> String? in
            if case let .text(value) = content { return value }
            return nil
        }.joined(separator: "\n")
    }

    /// The generic retry prompt. Inject a corrective prompt at init when the domain needs one
    /// that names its own format or tags.
    private static func defaultCorrectivePrompt(_ issues: [String], _ originalInput: String) -> String {
        "Your previous response was invalid: \(issues.joined(separator: "; ")). "
        + "Generate a corrected response that fixes these issues. "
        + "Original request: \(originalInput)"
    }

    private func setHistory(_ messages: [LLMMessage]) {
        history = messages
    }

    private func makeLoop(telemetry: AgentTelemetrySink? = nil) async -> AgentLoop<Client> {
        // With no workers registered, neither the delegation tools nor the delegating prompt are
        // injected. Leaving the vocabulary in place makes small on-device models reach for tools
        // that do not exist, degrading both their tool choice and their answers.
        // The roster is read per turn, so a worker registered later is picked up here.
        let roster = await registry.rosterJSONLines()
        let active = await registry.activeAgent
        let hasAgents = !roster.isEmpty
        return AgentLoop(
            client: client,
            model: model,
            tools: makeTools(includeDelegation: hasAgents),
            systemPrompt: makeSystemPrompt(agents: roster, activeAgent: active, hasAgents: hasAgents),
            maxSteps: maxSteps,
            maxTokens: maxTokens,
            cachePolicy: cachePolicy,
            telemetry: telemetry
        )
    }

    private func makeTools(includeDelegation: Bool) -> ToolSet {
        guard includeDelegation else { return extraTools }
        return extraTools + ToolSet {
            ListRemoteAgentsTool(registry: registry)
            SendMessageTool(registry: registry)
            DelegateAsyncTool(registry: registry)
            CheckTaskTool(registry: registry)
            ListRunningTasksTool(registry: registry)
        }
    }

    private func makeSystemPrompt(agents: String, activeAgent: String, hasAgents: Bool) -> SystemPrompt {
        let base = hasAgents
            ? HostInstruction.root(agents: agents, activeAgent: activeAgent)
            : HostInstruction.solo()
        let text = outputInstruction.map { "\(base)\n\n\($0)" } ?? base
        return SystemPrompt(stringLiteral: text)
    }
}
