import Foundation
import Testing
import AgentLoopKit
@testable import AgentRuntime

private enum MockError: Error { case unused }

// MARK: - Workers (in-process)

/// startWork → working → artifact「結果」→ complete（モード差を観測できる速度）。
private struct SlowExecutor: AgentExecutor {
    func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()
        try await Task.sleep(for: .milliseconds(20))
        try await updater.updateStatus(.working, message: updater.newAgentMessage([.text("作業中")]))
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

/// 受け取ったユーザー入力をそのままレポートにエコーするワーカー（呼び出し回数を数える）。
private struct EchoExecutor: AgentExecutor {
    let counter: Counter
    func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        await counter.increment()
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()
        await updater.addArtifact([.text("report:\(context.getUserInput())")], name: "result")
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

/// 1 ターンで research を観点の数だけ並列に呼び、結果が揃ったら統合する決定論的オーケストレータ。
private struct ParallelOrchestratorClient: AgentCapableClient {
    typealias Model = String
    let perspectives: [String]

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?) async throws -> LLMResponse {
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
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
}

/// `delegate` でワーカーに 1 観点を委譲し、レポートを返すツール。
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

        #expect(result.text == "結果")              // artifact を集約
        #expect(result.finalState == .completed)     // 終端まで消費（ブロッキング）
        #expect(await states.list.contains(.working)) // 待機中の進捗を tap できた
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

        #expect(await counter.value == 3)   // 観点ごとに独立した委譲が走った
        #expect(final.contains("基礎"))
        #expect(final.contains("応用"))
        #expect(final.contains("課題"))
    }
}
