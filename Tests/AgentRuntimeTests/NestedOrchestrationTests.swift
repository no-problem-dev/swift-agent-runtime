import LLMAgentStep
import LLMTool
import LLMClient
import Foundation
import Testing
import A2AServer
import A2AInProcess
@testable import AgentRuntime

private enum MockError: Error { case unused }

/// Leaf worker: answers with fixed text and never delegates further.
private struct FixedReplyClient: AgentCapableClient {
    typealias Model = String
    let replyText: String
    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        LLMResponse(content: [.text(replyText)], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

/// Delegates once and prefixes the reply, so each nesting level leaves a visible mark.
private struct DelegatingClient: AgentCapableClient {
    typealias Model = String
    let target: String
    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
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
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
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
        // Leaf worker.
        let wCard = makeCard("w")
        let registryA = AgentConnectionRegistry()
        await registryA.register(card: wCard, handler: DefaultRequestHandler(
            agentCard: wCard,
            executor: LLMAgentExecutor(client: FixedReplyClient(replyText: "W output"), model: "mock")
        ))

        // Middle orchestrator, exposed as a worker so the top one can delegate to it.
        let aCard = makeCard("a")
        let aExecutor = HostAgentExecutor {
            HostAgent(client: DelegatingClient(target: "w"), model: "mock", registry: registryA, maxSteps: 6)
        }

        // Top orchestrator.
        let registryB = AgentConnectionRegistry()
        await registryB.register(card: aCard, handler: DefaultRequestHandler(agentCard: aCard, executor: aExecutor))
        let sessionB = HostAgent(client: DelegatingClient(target: "a"), model: "mock", registry: registryB, maxSteps: 6)

        let result = try await sessionB.run("do it")
        // Two prefixes means the request really passed through both levels.
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
