import LLMTool
import LLMCore
import LLMAgentStep
import LLMClient
import Foundation
import Testing
import A2ACore
import A2AServer
@testable import AgentRuntime

// MARK: - Mocks

private enum MockError: Error { case unused }

/// Always plans a transfer to the named worker, so routing is deterministic.
private struct RoutingPlanClient: AgentCapableClient {
    typealias Model = String
    let targetName: String

    func planToolCalls(
        messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?,
        systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy
    ) async throws -> ToolCallResponse {
        let arguments = try JSONEncoder().encode(["agent_name": targetName])
        return ToolCallResponse(
            toolCalls: [ToolCall(id: "call_1", name: "transfer_to_agent", arguments: arguments)],
            text: nil,
            usage: TokenUsage(inputTokens: 10, outputTokens: 5),
            stopReason: .toolUse,
            model: "mock"
        )
    }

    func executeAgentStep(
        messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet,
        toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode,
        reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy
    ) async throws -> LLMResponse { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

/// Throws from every method, so any use of the model fails the test rather than passing quietly.
private struct NeverCalledClient: AgentCapableClient {
    typealias Model = String
    struct Unexpected: Error {}

    func planToolCalls(
        messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?,
        systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy
    ) async throws -> ToolCallResponse { throw Unexpected() }

    func executeAgentStep(
        messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet,
        toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode,
        reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy
    ) async throws -> LLMResponse { throw Unexpected() }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw Unexpected() }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw Unexpected() }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw Unexpected() }
}

/// Keeps what the worker actually received, so outbound rewriting can be checked at the far end.
private actor ReceivedMessages {
    private(set) var messages: [Message] = []
    func append(_ message: Message?) {
        if let message { messages.append(message) }
    }
}

private struct PartsEchoExecutor: AgentExecutor {
    let received: ReceivedMessages
    let replyParts: [Part]

    func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        await received.append(context.message)
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()
        await updater.addArtifact(replyParts, name: "response", metadata: nil)
        try await updater.complete()
    }

    func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.cancel()
    }
}

private func makeCard(_ name: String) -> AgentCard {
    AgentCard(
        name: name, description: "worker \(name)",
        supportedInterfaces: [AgentInterface(url: "inprocess://\(name)", protocolBinding: "InProcess")],
        version: "1.0.0",
        capabilities: AgentCapabilities(streaming: true)
    )
}

private let uiDataPart = Part.data(
    .object(["version": .string("v0.10"), "createSurface": .object(["surfaceId": .string("s1"), "catalogId": .string("cat")])]),
    mediaType: "application/a2ui+json"
)

private func makeRegistry(replyParts: [Part]) async -> (AgentConnectionRegistry, ReceivedMessages) {
    let registry = AgentConnectionRegistry()
    let received = ReceivedMessages()
    let card = makeCard("alpha")
    await registry.register(card: card, executor: PartsEchoExecutor(received: received, replyParts: replyParts))
    return (registry, received)
}

private func collect<C: AgentCapableClient>(
    _ stream: AsyncThrowingStream<RouterHostAgent<C>.Event, Error>
) async throws -> (routed: [(agent: String, deterministic: Bool)], workerParts: [Part]) {
    var routed: [(String, Bool)] = []
    var workerParts: [Part] = []
    for try await event in stream {
        switch event {
        case .routed(let agent, let deterministic, _):
            routed.append((agent, deterministic))
        case .worker(let response):
            if case .artifactUpdate(let update) = response { workerParts += update.artifact.parts }
            if case .task(let task) = response { workerParts += task.artifacts.flatMap(\.parts) }
        }
    }
    return (routed, workerParts)
}

// MARK: - Tests

@Suite("RouterHostAgent")
struct RouterHostAgentTests {
    @Test func routesViaLLMAndPassesPartsThrough() async throws {
        let (registry, _) = await makeRegistry(replyParts: [.text("done"), uiDataPart])
        let router = RouterHostAgent(client: RoutingPlanClient(targetName: "alpha"), model: "mock", registry: registry)

        let (routed, workerParts) = try await collect(router.send([.text("research swiftui")]))

        #expect(routed.count == 1)
        #expect(routed.first?.agent == "alpha")
        #expect(routed.first?.deterministic == false)
        // The structured part survived: it was passed through, not flattened to text.
        #expect(workerParts.contains { $0.mediaType == "application/a2ui+json" })
        #expect(workerParts.contains { $0.text == "done" })

        // The exchange was recorded as routing context for the next message.
        let history = await router.messages
        #expect(history.count == 2)
    }

    @Test func preRouteBypassesLLM() async throws {
        let (registry, _) = await makeRegistry(replyParts: [.text("ok")])
        let hooks = RouterHostAgent<NeverCalledClient>.Hooks(preRoute: { _ in "alpha" })
        // Any model call would throw, so passing proves the hook decided on its own.
        let router = RouterHostAgent(client: NeverCalledClient(), model: "mock", registry: registry, hooks: hooks)

        let (routed, _) = try await collect(router.send([.text("tap")]))
        #expect(routed.first?.agent == "alpha")
        #expect(routed.first?.deterministic == true)
    }

    @Test func prepareOutboundMetadataReachesWorker() async throws {
        let (registry, received) = await makeRegistry(replyParts: [.text("ok")])
        let hooks = RouterHostAgent<RoutingPlanClient>.Hooks(prepareOutbound: { metadata, target in
            var result = metadata ?? [:]
            result["routedTo"] = .string(target)
            return result
        })
        let router = RouterHostAgent(client: RoutingPlanClient(targetName: "alpha"), model: "mock", registry: registry, hooks: hooks)

        _ = try await collect(router.send([.text("hello")], metadata: ["trace": .string("t1")]))

        let messages = await received.messages
        #expect(messages.count == 1)
        #expect(messages.first?.metadata?["routedTo"]?.stringValue == "alpha")
        #expect(messages.first?.metadata?["trace"]?.stringValue == "t1")
        // Rewriting the metadata left the parts untouched.
        #expect(messages.first?.parts.first?.text == "hello")
    }

    @Test func observeWorkerPartsSeesStructuredParts() async throws {
        let (registry, _) = await makeRegistry(replyParts: [uiDataPart])
        let counter = PartCounter()
        let hooks = RouterHostAgent<RoutingPlanClient>.Hooks(observeWorkerParts: { parts, agent in
            await counter.add(parts.filter { $0.mediaType == "application/a2ui+json" }.count, agent: agent)
        })
        let router = RouterHostAgent(client: RoutingPlanClient(targetName: "alpha"), model: "mock", registry: registry, hooks: hooks)

        _ = try await collect(router.send([.text("draw")]))

        #expect(await counter.total > 0)
        #expect(await counter.agents == ["alpha"])
    }

    @Test func unknownTargetThrows() async throws {
        let (registry, _) = await makeRegistry(replyParts: [.text("ok")])
        let hooks = RouterHostAgent<NeverCalledClient>.Hooks(preRoute: { _ in "ghost" })
        let router = RouterHostAgent(client: NeverCalledClient(), model: "mock", registry: registry, hooks: hooks)

        await #expect(throws: AgentRuntimeError.unknownAgent("ghost")) {
            _ = try await collect(router.send([.text("hello")]))
        }
    }
}

private actor PartCounter {
    private(set) var total = 0
    private(set) var agents: Set<String> = []
    func add(_ count: Int, agent: String) {
        total += count
        agents.insert(agent)
    }
}
