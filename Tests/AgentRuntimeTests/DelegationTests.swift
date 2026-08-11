import LLMTool
import LLMClient
import LLMCore
import A2ACore
import LLMAgentStep
import Foundation
import Testing
import AgentLoopKit
import A2AServer
import A2AInProcess
@testable import AgentRuntime

private enum MockError: Error { case unused }

// MARK: - Workers (in-process)

/// Emits an intermediate working update between start and finish, slowly enough that a delivery
/// mode which shows progress can be told apart from one that does not.
private struct SlowExecutor: AgentExecutor {
    func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()
        try await Task.sleep(for: .milliseconds(20))
        try await updater.updateStatus(.working, message: updater.makeAgentMessage([.text("作業中")]))
        try await Task.sleep(for: .milliseconds(20))
        await updater.addArtifact([.text("結果")], name: "result")
        try await updater.complete()
    }
    func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {}
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Echoes its input back and counts invocations, so each delegation is individually identifiable.
private struct EchoExecutor: AgentExecutor {
    let counter: Counter
    func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        await counter.increment()
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()
        await updater.addArtifact([.text("report:\(context.userInput())")], name: "result")
        try await updater.complete()
    }
    func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {}
}

private func makeWorker(_ executor: any AgentExecutor) -> A2AClient {
    let card = AgentCard(
        name: "researcher", description: "researcher",
        supportedInterfaces: [AgentInterface(url: "inprocess://local", protocolBinding: "InProcess")],
        version: "1.0.0", capabilities: AgentCapabilities(streaming: true)
    )
    return A2AClient.inProcess(handler: DefaultRequestHandler(agentCard: card, executor: executor))
}

// MARK: - Orchestrator (deterministic fake LLM)

/// Requests one research call per perspective in a single step, then merges the results.
private struct ParallelOrchestratorClient: AgentCapableClient {
    typealias Model = String
    let perspectives: [String]

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        var toolResults: [String] = []
        for message in messages {
            for content in message.contents {
                if case .toolResult(_, _, let resultContent) = content {
                    switch resultContent {
                    case .success(let t): toolResults.append(t)
                    case .failure(let t): toolResults.append(t)
                    }
                }
            }
        }
        if !toolResults.isEmpty {
            return LLMResponse(content: [.text("統合: " + toolResults.joined(separator: " | "))], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
        }
        let uses = perspectives.enumerated().map { index, perspective -> LLMResponse.ContentBlock in
            let input = (try? JSONEncoder().encode(["perspective": perspective])) ?? Data()
            return .toolUse(id: "c\(index)", name: "research", input: input)
        }
        return LLMResponse(content: uses, model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .toolUse)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

/// A tool whose body is a blocking delegation, which is how a tool call becomes a sub-agent call.
private struct DelegateResearchTool: Tool {
    let client: A2AClient
    let mode: DeliveryMode

    var toolName: String { "research" }
    var toolDescription: String { "Delegate one perspective to the researcher." }
    var inputSchema: JSONSchema {
        .object(properties: ["perspective": .string(description: "perspective")], required: ["perspective"])
    }
    func execute(with argumentsData: Data) async throws -> ToolResult {
        let args = (try? JSONDecoder().decode([String: String].self, from: argumentsData)) ?? [:]
        let perspective = args["perspective"] ?? "?"
        let result = try await client.delegate("調査:\(perspective)", mode: mode)
        return .text("[\(perspective)] \(result.text)")
    }
}

// MARK: - Tests

@Suite("Blocking delegation that taps the stream for live progress")
struct DelegationTests {

    @Test("streaming 委譲: 待機中の working を tap しつつ、最終レポートを集約して返す")
    func streamingDelegateTapsAndAggregates() async throws {
        let client = makeWorker(SlowExecutor())
        actor States {
            private(set) var list: [TaskState] = []
            func add(_ s: TaskState) { list.append(s) }
        }
        let states = States()

        let result = try await client.delegate("go", mode: .streaming) { event in
            switch event {
            case .statusUpdate(let u): await states.add(u.status.state)
            case .task(let t): await states.add(t.status.state)
            default: break
            }
        }

        #expect(result.text == "結果")              // artifacts aggregated
        #expect(result.finalState == .completed)     // consumed to the end before returning
        #expect(await states.list.contains(.working)) // progress was visible while blocked
    }

    @Test("blocking 委譲: 終端の結果だけを集約して返す")
    func blockingDelegateAggregates() async throws {
        let client = makeWorker(SlowExecutor())
        let result = try await client.delegate("go", mode: .blocking)
        #expect(result.text == "結果")
        #expect(result.finalState == .completed)
    }

    @Test("並列委譲: 1 ターンで research を3回 → 独立タスク3つ、全レポートを集約")
    func parallelDelegationInOneTurn() async throws {
        let counter = Counter()
        let worker = makeWorker(EchoExecutor(counter: counter))
        let tools = ToolSet { DelegateResearchTool(client: worker, mode: .streaming) }
        let loop = AgentLoop(
            client: ParallelOrchestratorClient(perspectives: ["基礎", "応用", "課題"]),
            model: "mock",
            tools: tools,
            maxSteps: 4
        )

        var final = ""
        _ = try await loop.run(messages: [.user("AIエージェントを調べて")]) { event in
            if case .completed(let text) = event { final = text }
        }

        #expect(await counter.value == 3)   // one independent delegation per perspective
        #expect(final.contains("基礎"))
        #expect(final.contains("応用"))
        #expect(final.contains("課題"))
    }
}
