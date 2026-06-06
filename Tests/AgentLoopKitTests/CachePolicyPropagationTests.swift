import Foundation
import Testing
@testable import AgentLoopKit

/// executeAgentStep が受け取った cachePolicy を記録する probe クライアント。
private actor PolicyRecorder {
    var policies: [PromptCachePolicy] = []
    func record(_ policy: PromptCachePolicy) { policies.append(policy) }
}

private struct PolicyCapturingClient: AgentCapableClient {
    typealias Model = String
    let recorder: PolicyRecorder

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        await recorder.record(cachePolicy)
        return LLMResponse(content: [.text("ok")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { fatalError("unused") }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { fatalError("unused") }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { fatalError("unused") }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { fatalError("unused") }
}

@Suite("CachePolicy の伝播")
struct CachePolicyPropagationTests {

    @Test("AgentLoop は指定された cachePolicy を毎ステップそのまま渡す")
    func propagatesExplicitPolicy() async throws {
        let recorder = PolicyRecorder()
        let loop = AgentLoop(
            client: PolicyCapturingClient(recorder: recorder),
            model: "mock",
            systemPrompt: "prompt",
            cachePolicy: .explicitPrefix(ttl: .seconds(1800))
        )
        try await loop.run(messages: [.user("hi")]) { _ in }

        let policies = await recorder.policies
        #expect(policies == [.explicitPrefix(ttl: .seconds(1800))])
    }

    @Test("既定は implicit（現状維持）")
    func defaultsToImplicit() async throws {
        let recorder = PolicyRecorder()
        let loop = AgentLoop(
            client: PolicyCapturingClient(recorder: recorder),
            model: "mock"
        )
        try await loop.run(messages: [.user("hi")]) { _ in }

        let policies = await recorder.policies
        #expect(policies == [.implicit])
    }
}
