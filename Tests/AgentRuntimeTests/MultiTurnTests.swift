import LLMTool
import LLMClient
import LLMCore
import A2ACore
import LLMAgentStep
import Foundation
import Testing
@testable import AgentRuntime

private enum MockError: Error { case unused }

/// Answers with every user message it was given, making the carried-over history observable.
private struct HistoryEchoClient: AgentCapableClient {
    typealias Model = String

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        let userTexts = messages
            .filter { $0.role == .user }
            .map { message in
                message.contents.compactMap { content -> String? in
                    if case .text(let t) = content { return t }
                    return nil
                }.joined()
            }
            .joined(separator: " ")
        return LLMResponse(content: [.text(userTexts)], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

@Suite("HostAgent multi-turn continuity")
struct MultiTurnTests {

    @Test("2 ターン目は 1 ターン目の文脈（user 履歴）を引き継ぐ")
    func carriesHistoryAcrossTurns() async throws {
        let session = HostAgent(client: HistoryEchoClient(), model: "mock", registry: AgentConnectionRegistry())

        let first = try await session.run("alpha")
        #expect(first == "alpha")

        let second = try await session.run("beta")
        // With history carried over, the second turn sees both messages.
        #expect(second.contains("alpha"))
        #expect(second.contains("beta"))

        // Two turns of user plus assistant.
        let history = await session.messages
        #expect(history.count == 4)
    }

    @Test("clear() で履歴がリセットされ、以降は新規入力のみを見る")
    func clearResetsHistory() async throws {
        let session = HostAgent(client: HistoryEchoClient(), model: "mock", registry: AgentConnectionRegistry())

        _ = try await session.run("alpha")
        await session.clear()
        #expect(await session.messages.isEmpty)

        let afterClear = try await session.run("gamma")
        #expect(afterClear == "gamma")
        #expect(!afterClear.contains("alpha"))
    }
}
