import Foundation
import Testing
@testable import AgentRuntime

private enum MockError: Error { case unused }

private actor CancelFlag {
    private(set) var cancelled = false
    func mark() { cancelled = true }
}

/// input-required で中断する手書きワーカー（キャンセル対象を非終端にする）。
private struct PausingExecutor: AgentExecutor {
    func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()
        try await updater.requiresInput(message: updater.newAgentMessage([.text("need input")]))
    }
    func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.cancel()
    }
}

/// executeAgentStep で停止し続けるワーカー用クライアント。
private struct HangingWorkerClient: AgentCapableClient {
    typealias Model = String
    let flag: CancelFlag
    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        do { try await Task.sleep(for: .seconds(5)) } catch { await flag.mark(); throw error }
        return LLMResponse(content: [.text("done")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

private struct AlwaysDelegateClient: AgentCapableClient {
    typealias Model = String
    let target: String
    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        let input = try JSONEncoder().encode(["agent_name": target, "message": "go"])
        return LLMResponse(content: [.toolUse(id: "c1", name: "send_message", input: input)], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .toolUse)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

private func makeCard(_ name: String) -> AgentCard {
    AgentCard(
        name: name, description: "worker \(name)",
        supportedInterfaces: [AgentInterface(url: "inprocess://local", protocolBinding: "InProcess")],
        version: "1.0.0", capabilities: AgentCapabilities(streaming: true)
    )
}

@Suite("cancel() API (registry & HostAgent)")
struct CancelAPITests {

    @Test("registry.cancel は中断中ワーカーを canceled にする。未登録/未開始は nil")
    func registryCancel() async throws {
        let registry = AgentConnectionRegistry()
        let card = makeCard("weather")
        await registry.register(card: card, handler: DefaultRequestHandler(agentCard: card, executor: PausingExecutor()))

        #expect(await registry.cancel("weather") == nil)   // まだ送っていない（taskId 無し）
        #expect(await registry.cancel("ghost") == nil)      // 未登録

        let outcome = try await registry.send(to: "weather", text: "go")
        #expect(outcome.state == .inputRequired)

        let state = await registry.cancel("weather")
        #expect(state == .canceled)
    }

    @Test("registry.cancelAll は best-effort（完了済みワーカーでも throw しない）")
    func registryCancelAllBestEffort() async throws {
        struct Done: AgentExecutor {
            func execute(_ c: RequestContext, eventQueue q: EventQueue) async throws {
                let u = TaskUpdater(eventQueue: q, taskId: c.taskId, contextId: c.contextId); try await u.complete()
            }
            func cancel(_ c: RequestContext, eventQueue q: EventQueue) async throws {}
        }
        let registry = AgentConnectionRegistry()
        let card = makeCard("done")
        await registry.register(card: card, handler: DefaultRequestHandler(agentCard: card, executor: Done()))
        _ = try await registry.send(to: "done", text: "go")   // 完了 → taskId は終端

        await registry.cancelAll()   // throw しなければ OK
    }

    @Test("session.cancel() は in-flight run を止め、委譲中の実行ワーカーも停止する")
    func sessionCancel() async throws {
        let flag = CancelFlag()
        let card = makeCard("worker")
        let registry = AgentConnectionRegistry()
        await registry.register(card: card, handler: DefaultRequestHandler(agentCard: card, executor: LLMAgentExecutor(client: HangingWorkerClient(flag: flag), model: "mock")))

        let session = HostAgent(client: AlwaysDelegateClient(target: "worker"), model: "mock", registry: registry, maxSteps: 4)

        let runTask = Task { try await session.run("do it") }
        try await Task.sleep(for: .milliseconds(100))   // ワーカーが hang するまで待つ

        await session.cancel()

        do {
            _ = try await runTask.value
            Issue.record("expected run to be cancelled")
        } catch {
            // 期待どおり
        }
        #expect(await flag.cancelled)
    }
}
