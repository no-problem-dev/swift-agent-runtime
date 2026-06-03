import Foundation
import Testing
@testable import AgentRuntime

private enum MockError: Error { case unused }

/// 固定テキストを返すワーカー用クライアント。
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

/// 指定ワーカーへ委譲し、結果に "FINAL: " を付けて返すオーケストレータ用クライアント。
private struct DelegatingClient: AgentCapableClient {
    typealias Model = String
    let target: String
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
        let input = try JSONEncoder().encode(["agent_name": target, "message": "go"])
        return LLMResponse(content: [.toolUse(id: "c1", name: "send_message", input: input)], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .toolUse)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
}

private func makeCard(_ name: String) -> AgentCard {
    AgentCard(
        name: name, description: "agent \(name)",
        supportedInterfaces: [AgentInterface(url: "inprocess://local", protocolBinding: "InProcess")],
        version: "1.0.0", capabilities: AgentCapabilities(streaming: true)
    )
}

@Suite("Nested orchestration (orchestrator exposed as A2A worker)")
struct NestedOrchestrationTests {

    @Test("B → A → W: 中間オーケストレータ A を A2A ワーカーとして公開し、入れ子で委譲が通る")
    func nestedDelegation() async throws {
        // 末端ワーカー W
        let wCard = makeCard("w")
        let registryA = AgentConnectionRegistry()
        await registryA.register(card: wCard, handler: DefaultRequestHandler(
            agentCard: wCard,
            executor: LLMAgentExecutor(client: FixedReplyClient(replyText: "W output"), model: "mock")
        ))

        // 中間オーケストレータ A（W へ委譲）を HostAgentExecutor で A2A 公開
        let aCard = makeCard("a")
        let aExecutor = HostAgentExecutor {
            HostAgent(client: DelegatingClient(target: "w"), model: "mock", registry: registryA, maxSteps: 6)
        }

        // 上位オーケストレータ B（A へ委譲）
        let registryB = AgentConnectionRegistry()
        await registryB.register(card: aCard, handler: DefaultRequestHandler(agentCard: aCard, executor: aExecutor))
        let sessionB = HostAgent(client: DelegatingClient(target: "a"), model: "mock", registry: registryB, maxSteps: 6)

        let result = try await sessionB.run("do it")
        // B → A → W の二段委譲で "FINAL:" が 2 回付く
        #expect(result == "FINAL: FINAL: W output")
    }

    @Test("HostAgentExecutor 単体: in-process クライアントから呼ぶと completed + artifact を返す")
    func executorReturnsArtifact() async throws {
        let registry = AgentConnectionRegistry()
        let wCard = makeCard("w")
        await registry.register(card: wCard, handler: DefaultRequestHandler(
            agentCard: wCard,
            executor: LLMAgentExecutor(client: FixedReplyClient(replyText: "leaf"), model: "mock")
        ))
        let executor = HostAgentExecutor {
            HostAgent(client: DelegatingClient(target: "w"), model: "mock", registry: registry, maxSteps: 6)
        }
        let client = A2AClient.inProcess(handler: DefaultRequestHandler(agentCard: makeCard("a"), executor: executor))

        let response = try await client.sendMessage(
            Message(messageId: MessageID(UUID().uuidString), role: .user, parts: [.text("go")])
        )
        guard case .task(let task) = response else { Issue.record("expected task"); return }
        #expect(task.status.state == .completed)
        #expect(task.artifacts.first?.parts.first?.text == "FINAL: leaf")
    }
}
