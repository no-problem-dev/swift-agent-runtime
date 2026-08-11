import LLMClient
import LLMCore
import A2ACore
import LLMAgentStep
import LLMTool
import Foundation
import Testing
import A2AServer
import A2AInProcess
@testable import AgentRuntime

private enum MockError: Error { case unused }

private actor CallCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Counts how many times the worker was actually driven, which is the point of the assertion.
private struct CountingWorkerClient: AgentCapableClient {
    typealias Model = String
    let reply: String
    let counter: CallCount
    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        await counter.increment()
        return LLMResponse(content: [.text(reply)], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

/// Delegates only when the conversation holds no tool result yet; otherwise answers from context.
private struct FollowUpClient: AgentCapableClient {
    typealias Model = String
    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
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
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
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

        // Turn one delegates.
        let first = try await session.run("SwiftUIを調べて")
        #expect(first.contains("宣言的"))

        // Turn two is a follow-up: the earlier result is still in the history.
        let second = try await session.run("さっき何を調べたんだっけ？")
        #expect(second.contains("宣言的"))

        // So the worker ran once, not twice — the second answer came from context.
        #expect(await counter.value == 1)
    }
}
