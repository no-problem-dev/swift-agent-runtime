import Foundation
import Testing
@testable import AgentRuntime

private enum MockError: Error { case unused }

/// ワーカー用: 固定テキストを返すだけ。
private struct FixedReplyClient: AgentCapableClient {
    typealias Model = String
    let replyText: String
    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?) async throws -> LLMResponse {
        LLMResponse(content: [.text(replyText)], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
}

/// オーケストレータ用: まず send_message を呼び、tool 結果が来たら "FINAL: <結果>" を返す。
private struct DelegatingMockClient: AgentCapableClient {
    typealias Model = String
    let targetAgent: String

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?) async throws -> LLMResponse {
        var toolResultText: String?
        for message in messages {
            for content in message.contents {
                if case .toolResult(_, _, let resultContent) = content {
                    switch resultContent {
                    case .success(let text): toolResultText = text
                    case .failure(let text): toolResultText = text
                    }
                }
            }
        }
        if let toolResultText {
            return LLMResponse(content: [.text("FINAL: \(toolResultText)")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
        }
        let input = try JSONEncoder().encode(["agent_name": targetAgent, "message": "subtask"])
        return LLMResponse(content: [.toolUse(id: "c1", name: "send_message", input: input)], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .toolUse)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
}

private func makeWorkerHandler(name: String, reply: String) -> (AgentCard, DefaultRequestHandler) {
    let card = AgentCard(
        name: name, description: "worker \(name)",
        supportedInterfaces: [AgentInterface(url: "inprocess://local", protocolBinding: "InProcess")],
        version: "1.0.0", capabilities: AgentCapabilities(streaming: true)
    )
    let executor = LLMAgentExecutor(client: FixedReplyClient(replyText: reply), model: "mock")
    return (card, DefaultRequestHandler(agentCard: card, executor: executor))
}

@Suite("AgentSession (orchestrator)")
struct AgentSessionTests {

    @Test("ホストがワーカーへ委譲し、ワーカー応答を取り込んだ最終テキストを返す（end-to-end）")
    func orchestratorDelegates() async throws {
        let registry = AgentConnectionRegistry()
        let (cardA, handlerA) = makeWorkerHandler(name: "researcher", reply: "research findings")
        let (cardB, handlerB) = makeWorkerHandler(name: "writer", reply: "drafted text")
        await registry.register(card: cardA, handler: handlerA)
        await registry.register(card: cardB, handler: handlerB)

        let session = AgentSession(
            client: DelegatingMockClient(targetAgent: "researcher"),
            model: "mock",
            registry: registry
        )

        let result = try await session.run("Find and summarize X")
        // オーケストレータは researcher に委譲し、その応答を最終テキストへ取り込む
        #expect(result == "FINAL: research findings")

        // 委譲によりワーカーのタスクが completed になっている（マルチターン継続用に state 保存）
        let outcome = try await registry.send(to: "researcher", text: "ping")
        #expect(outcome.state == .completed)
    }

    @Test("stream はツール委譲ステップと最終テキストを流す")
    func orchestratorStreams() async throws {
        let registry = AgentConnectionRegistry()
        let (card, handler) = makeWorkerHandler(name: "researcher", reply: "data")
        await registry.register(card: card, handler: handler)

        let session = AgentSession(client: DelegatingMockClient(targetAgent: "researcher"), model: "mock", registry: registry)

        var sawToolCall = false
        var finalText = ""
        for try await step in await session.stream("go") {
            switch step {
            case .toolCall(_, let name): if name == "send_message" { sawToolCall = true }
            case .completed(let text): finalText = text
            default: break
            }
        }
        #expect(sawToolCall)
        #expect(finalText == "FINAL: data")
    }
}
