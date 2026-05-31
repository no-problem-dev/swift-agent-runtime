import Foundation
import Testing
@testable import AgentRuntime

private enum MockError: Error { case unused }

/// ワーカーがキャンセルされたら記録するフラグ。
private actor CancelFlag {
    private(set) var cancelled = false
    func mark() { cancelled = true }
}

/// executeAgentStep でキャンセルされるまで停止するワーカー用クライアント。
/// 構造化キャンセルがツリーを伝播すれば、ここで CancellationError を観測する。
private struct HangingWorkerClient: AgentCapableClient {
    typealias Model = String
    let flag: CancelFlag

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?) async throws -> LLMResponse {
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            await flag.mark()
            throw error
        }
        return LLMResponse(content: [.text("done")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
}

/// 常に指定ワーカーへ委譲するオーケストレータ用クライアント。
private struct AlwaysDelegateClient: AgentCapableClient {
    typealias Model = String
    let target: String

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?) async throws -> LLMResponse {
        let input = try JSONEncoder().encode(["agent_name": target, "message": "go"])
        return LLMResponse(content: [.toolUse(id: "c1", name: "send_message", input: input)], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .toolUse)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
}

@Suite("Structured cancellation propagation")
struct CancellationPropagationTests {

    @Test("session.run を包む Task をキャンセルすると、委譲先の実行中ワーカーまでツリーで停止する")
    func cancellationReachesWorker() async throws {
        let flag = CancelFlag()
        let card = AgentCard(
            name: "worker", description: "hanging worker",
            supportedInterfaces: [AgentInterface(url: "inprocess://local", protocolBinding: "InProcess")],
            version: "1.0.0", capabilities: AgentCapabilities(streaming: true)
        )
        let registry = AgentConnectionRegistry()
        let workerExecutor = LLMAgentExecutor(client: HangingWorkerClient(flag: flag), model: "mock")
        await registry.register(card: card, handler: DefaultRequestHandler(agentCard: card, executor: workerExecutor))

        let session = AgentSession(client: AlwaysDelegateClient(target: "worker"), model: "mock", registry: registry)

        let runTask = Task { try await session.run("do it") }
        // ワーカーが Task.sleep に到達するまで待つ。
        try await Task.sleep(for: .milliseconds(100))
        runTask.cancel()

        // run はキャンセルで終わる。
        do {
            _ = try await runTask.value
            Issue.record("expected cancellation to propagate")
        } catch {
            // 期待どおり（CancellationError）
        }

        // 委譲先の実行中ワーカーまでキャンセルが伝播していること。
        #expect(await flag.cancelled)
    }
}
