import Foundation
import Testing
@testable import AgentRuntime

private enum MockError: Error { case unused }

private actor CallCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// 委譲されたら実行回数を数え、固定レポートを返すワーカー。
private struct CountingWorkerClient: AgentCapableClient {
    typealias Model = String
    let reply: String
    let counter: CallCount
    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?) async throws -> LLMResponse {
        await counter.increment()
        return LLMResponse(content: [.text(reply)], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
}

/// 会話にツール結果が無ければ委譲し、あればそれを文脈から答える（状況ツール無し）。
private struct FollowUpClient: AgentCapableClient {
    typealias Model = String
    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?) async throws -> LLMResponse {
        var lastToolResult: String?
        var lastUser = ""
        for message in messages {
            if message.role == .user {
                let text = message.contents.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
                if !text.isEmpty { lastUser = text }
            }
            for content in message.contents {
                if case .toolResult(_, _, let resultContent) = content {
                    switch resultContent {
                    case .success(let t): lastToolResult = t
                    case .failure(let t): lastToolResult = t
                    }
                }
            }
        }
        if let lastToolResult {
            return LLMResponse(content: [.text("前回の調査結果: \(lastToolResult)")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
        }
        let input = try JSONEncoder().encode(["agent_name": "researcher", "message": lastUser])
        return LLMResponse(content: [.toolUse(id: "c1", name: "send_message", input: input)], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .toolUse)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
}

@Suite("Follow-up answered from conversation context (no status tool)")
struct FollowUpContextTests {

    @Test("委譲結果は会話に残り、follow-up は再委譲せず文脈から答えられる")
    func followUpUsesContext() async throws {
        let counter = CallCount()
        let card = AgentCard(
            name: "researcher", description: "researcher",
            supportedInterfaces: [AgentInterface(url: "inprocess://local", protocolBinding: "InProcess")],
            version: "1.0.0", capabilities: AgentCapabilities(streaming: true)
        )
        let registry = AgentConnectionRegistry()
        await registry.register(
            card: card,
            handler: DefaultRequestHandler(
                agentCard: card,
                executor: LLMAgentExecutor(client: CountingWorkerClient(reply: "SwiftUIは宣言的UIフレームワーク", counter: counter), model: "mock")
            )
        )
        let session = HostAgent(client: FollowUpClient(), model: "mock", registry: registry)

        // ターン1: 委譲が起きる
        let first = try await session.run("SwiftUIを調べて")
        #expect(first.contains("宣言的"))

        // ターン2: フォローアップ。文脈に調査結果が残っているので再委譲しない
        let second = try await session.run("さっき何を調べたんだっけ？")
        #expect(second.contains("宣言的"))

        // ワーカーは 1 回しか呼ばれていない（ターン2 は文脈から回答）
        #expect(await counter.value == 1)
    }
}
