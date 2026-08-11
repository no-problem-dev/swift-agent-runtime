import AgentLoopKit
import A2ACore
import LLMClient
import LLMTool
import LLMAgentStep
import Foundation

/// A host that forwards a message to exactly one worker and passes the reply straight back.
///
/// Use this instead of the aggregating host when the worker's output is structured and must reach
/// the client intact — the aggregating host joins everything into text, which destroys it. The
/// router never composes an answer of its own, so its prompt is one routing sentence plus the
/// roster, and it holds no domain knowledge at all.
///
/// Routing costs one model call per message, unless a hook decides without the model.
public actor RouterHostAgent<Client: AgentCapableClient> where Client.Model: Sendable {

    /// Where domain-specific behaviour is injected, keeping the router itself generic.
    public struct Hooks: Sendable {
        /// Decides the target without asking the model. Return `nil` to fall back to the model,
        /// which is the default. Use it when the message already says where it belongs.
        public var preRoute: @Sendable ([Part]) async -> String?
        /// Rewrites the message metadata just before it goes out, once the target is known.
        /// Throwing here aborts the send after routing has already been reported.
        public var prepareOutbound: @Sendable (A2AMetadata?, _ target: String) async throws -> A2AMetadata?
        /// Observes the worker's reply parts as they stream by. Called before the parts are
        /// yielded onward, so a slow hook delays the client.
        public var observeWorkerParts: @Sendable ([Part], _ agent: String) async -> Void

        public init(
            preRoute: @escaping @Sendable ([Part]) async -> String? = { _ in nil },
            prepareOutbound: @escaping @Sendable (A2AMetadata?, String) async throws -> A2AMetadata? = { metadata, _ in metadata },
            observeWorkerParts: @escaping @Sendable ([Part], String) async -> Void = { _, _ in }
        ) {
            self.preRoute = preRoute
            self.prepareOutbound = prepareOutbound
            self.observeWorkerParts = observeWorkerParts
        }
    }

    public enum Event: Sendable {
        /// The target was chosen. `deterministic` means a hook decided and no model call happened,
        /// which is also why `usage` is `nil` in that case.
        case routed(agent: String, deterministic: Bool, usage: TokenUsage?)
        /// A worker event, forwarded unchanged.
        case worker(StreamResponse)
    }

    private let client: Client
    private let model: Client.Model
    private let registry: AgentConnectionRegistry
    private let hooks: Hooks
    private let maxTokens: Int?
    private let cachePolicy: PromptCachePolicy
    private var history: [LLMMessage] = []

    public init(
        client: Client,
        model: Client.Model,
        registry: AgentConnectionRegistry,
        hooks: Hooks = Hooks(),
        maxTokens: Int? = nil,
        cachePolicy: PromptCachePolicy = .implicit
    ) {
        self.client = client
        self.model = model
        self.registry = registry
        self.hooks = hooks
        self.maxTokens = maxTokens
        self.cachePolicy = cachePolicy
    }

    /// The routing conversation: each user message and a summary of what the worker replied.
    /// Kept so the next routing decision can see the flow of the conversation, not the full
    /// worker output. Grows with every message; nothing trims it.
    public var messages: [LLMMessage] { history }

    /// Forgets the routing conversation. The next message is routed without prior context.
    public func clear() {
        history.removeAll()
    }

    /// Asks every worker to stop. Does not interrupt a routing decision already in flight — end
    /// the stream for that.
    public func cancel() async {
        await registry.cancelAll()
    }

    /// Releases server-side prompt caches held by the client, where the provider bills for them.
    /// Does nothing for clients without that concept.
    public func close() async {
        if let releasing = client as? PromptCacheReleasing {
            await releasing.releasePromptCaches()
        }
    }

    /// Routes one message to a single worker and streams the reply through unchanged.
    ///
    /// The work runs in an unstructured task, so it does not inherit the caller's cancellation —
    /// terminating the stream is what stops it. An unknown target, a model that produced no
    /// routing decision, or a throwing outbound hook all surface as an error on the stream.
    /// History is only appended once the worker's stream ends, so a failed send leaves it clean.
    public func send(_ parts: [Part], metadata: A2AMetadata? = nil) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.route(parts, metadata: metadata) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func route(
        _ parts: [Part],
        metadata: A2AMetadata?,
        yield: @Sendable (Event) -> Void
    ) async throws {
        let target: String
        let deterministic: Bool
        var routingUsage: TokenUsage?

        if let preRouted = await hooks.preRoute(parts) {
            target = preRouted
            deterministic = true
        } else {
            let decision = try await decideRoute(for: parts)
            target = decision.agent
            deterministic = false
            routingUsage = decision.usage
        }
        yield(.routed(agent: target, deterministic: deterministic, usage: routingUsage))

        let outbound = try await hooks.prepareOutbound(metadata, target)
        let stream = try await registry.stream(to: target, parts: parts, metadata: outbound)

        var workerTexts: [String] = []
        for try await event in stream {
            let workerParts = Self.parts(in: event)
            if !workerParts.isEmpty {
                await hooks.observeWorkerParts(workerParts, target)
                let text = Self.historyText(for: workerParts)
                if !text.isEmpty { workerTexts.append(text) }
            }
            yield(.worker(event))
        }

        // Keep the exchange as routing context, summarised rather than verbatim: the next
        // decision needs the shape of the conversation, not the worker's full output.
        history.append(try Self.userMessage(for: parts))
        let workerText = workerTexts.joined(separator: "\n")
        history.append(.assistant("[\(target)] \(workerText.isEmpty ? "(no text)" : workerText)"))
    }

    // MARK: - Model routing

    /// The routing prompt: one sentence plus the roster, and nothing else. The worker descriptions
    /// are the only thing the model has to route on, so they carry the whole decision.
    static func instruction(roster: String) -> String {
        """
        You are an orchestrator agent. Your sole responsibility is to analyze the incoming user request, determine the user's intent, and route the task to exactly one of your expert subagents

        Agents:
        \(roster)
        """
    }

    private struct TransferToAgentTool: Tool {
        var toolName: String { "transfer_to_agent" }
        var toolDescription: String { "Transfer the conversation to the named expert subagent." }
        var inputSchema: JSONSchema {
            .object(
                properties: [
                    "agent_name": .string(description: "The name of the agent to transfer to."),
                ],
                required: ["agent_name"]
            )
        }
        // Only ever planned, never executed: the router reads the intended call and forwards the
        // message itself. Reaching this body means the tool escaped into a real loop.
        func execute(with argumentsData: Data) async throws -> ToolResult {
            .error("transfer_to_agent is handled by the router, not executed as a tool")
        }
    }

    private struct TransferArguments: Decodable {
        let agent_name: String
    }

    private func decideRoute(for parts: [Part]) async throws -> (agent: String, usage: TokenUsage) {
        let roster = await registry.rosterJSONLines()
        let response = try await client.planToolCalls(
            messages: history + [try Self.userMessage(for: parts)],
            model: model,
            tools: ToolSet { TransferToAgentTool() },
            toolChoice: .tool("transfer_to_agent"),
            systemPrompt: SystemPrompt(stringLiteral: Self.instruction(roster: roster)),
            temperature: nil,
            maxTokens: maxTokens,
            cachePolicy: cachePolicy
        )
        guard let call = response.toolCalls.first(where: { $0.name == "transfer_to_agent" }) else {
            throw AgentRuntimeError.routingFailed("no transfer_to_agent call in response")
        }
        guard let arguments = try? JSONDecoder().decode(TransferArguments.self, from: call.arguments) else {
            throw AgentRuntimeError.routingFailed("malformed transfer_to_agent arguments")
        }
        return (arguments.agent_name, response.usage)
    }

    // MARK: - Part rendering

    private static func parts(in event: StreamResponse) -> [Part] {
        switch event {
        case .task(let task):
            task.artifacts.flatMap(\.parts) + (task.status.message?.parts ?? [])
        case .statusUpdate(let update):
            update.status.message?.parts ?? []
        case .artifactUpdate(let update):
            update.artifact.parts
        case .message(let message):
            message.parts
        }
    }

    /// Builds the routing input, carrying images through. Text-only messages produce exactly what
    /// the text-only path produced before attachments existed, so routing behaviour is unchanged.
    private static func userMessage(for parts: [Part]) throws -> LLMMessage {
        try MultimodalInput.userMessage(from: parts)
    }

    /// Renders worker parts as text for the routing history. Structured data becomes JSON; bytes
    /// and links are dropped, since the history exists to inform routing, not to preserve output.
    private static func historyText(for parts: [Part]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return parts.compactMap { part in
            switch part.content {
            case .text(let text):
                return text
            case .data:
                return (try? encoder.encode(part)).flatMap { String(data: $0, encoding: .utf8) }
            case .bytes, .uri:
                return nil
            }
        }.joined(separator: "\n")
    }
}
