import LLMTool
import LLMClient
import LLMCore
import A2ACore
import LLMAgentStep
import Foundation
import Testing
import A2AServer
import A2AInProcess
@testable import AgentRuntime

private enum MockError: Error { case unused }

/// Asks for input on the first step, then answers using whatever the user replied.
private struct InteractiveMockClient: AgentCapableClient {
    typealias Model = String

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        let hasPriorAssistantTurn = messages.contains { $0.role == .assistant }
        if hasPriorAssistantTurn {
            // Resuming: answer from the newest user message.
            let city = messages.last?.contents.compactMap { content -> String? in
                if case .text(let t) = content { return t }
                return nil
            }.joined() ?? ""
            return LLMResponse(content: [.text("Weather for \(city): sunny")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
        }
        // First step: ask instead of guessing.
        let input = try JSONEncoder().encode(["question": "Which city?"])
        return LLMResponse(content: [.toolUse(id: "c1", name: "request_user_input", input: input)], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .toolUse)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

private func makeInteractiveWorker() -> (AgentCard, DefaultRequestHandler) {
    let card = AgentCard(
        name: "weather", description: "weather worker",
        supportedInterfaces: [AgentInterface(url: "inprocess://local", protocolBinding: "InProcess")],
        version: "1.0.0", capabilities: AgentCapabilities(streaming: true)
    )
    let executor = LLMAgentExecutor(
        client: InteractiveMockClient(),
        model: "mock",
        tools: ToolSet { RequestUserInputTool() }
    )
    return (card, DefaultRequestHandler(agentCard: card, executor: executor))
}

@Suite("Interactive worker (request_user_input → input-required → resume)")
struct InteractiveWorkerTests {

    @Test("ワーカー: request_user_input → input-required、回答再送で resume → completed（実 LLM ループ）")
    func workerPausesThenResumes() async throws {
        let registry = AgentConnectionRegistry()
        let (card, handler) = makeInteractiveWorker()
        await registry.register(card: card, handler: handler)

        let first = try await registry.send(to: "weather", text: "what's the weather?")
        #expect(first.state == .inputRequired)
        #expect(first.text.contains("Which city?"))

        let second = try await registry.send(to: "weather", text: "Tokyo")
        #expect(second.state == .completed)
        #expect(second.text.contains("Weather for Tokyo"))
    }
}
