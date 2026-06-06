import Foundation
import Testing
@testable import AgentRuntime

private enum MockError: Error { case unused }

/// 受け取った会話中の user メッセージ本文を全て連結して返すクライアント。
/// マルチターンで履歴が引き継がれているかを観測するために使う。
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
        // 履歴が引き継がれていれば、2 ターン目は alpha と beta の両方を観測する
        #expect(second.contains("alpha"))
        #expect(second.contains("beta"))

        // 履歴は user/assistant の 2 ターン分 = 4 メッセージ
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
