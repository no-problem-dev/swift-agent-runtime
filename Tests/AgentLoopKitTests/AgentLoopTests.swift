import Foundation
import Testing
@testable import AgentLoopKit

private enum MockError: Error { case unused }

/// ツール呼び出し → 結果 → 最終テキストを順に返す scripted クライアント。
private struct ScriptedClient: AgentCapableClient {
    typealias Model = String
    /// true なら 1 回目に request_user_input（対話ツール）を呼ぶ。
    let askUser: Bool

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?) async throws -> LLMResponse {
        if askUser, !messages.contains(where: { $0.role == .assistant }) {
            let input = try JSONEncoder().encode(["question": "Which city?"])
            return LLMResponse(content: [.toolUse(id: "c1", name: "request_user_input", input: input)], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .toolUse)
        }
        return LLMResponse(content: [.text("final answer")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
}

@Suite("AgentLoop (generic, A2A-free)")
struct AgentLoopTests {

    @Test("ツール無しの応答は即 completed")
    func completesWithoutTools() async throws {
        let loop = AgentLoop(client: ScriptedClient(askUser: false), model: "mock")
        var final: String?
        for try await event in loop.run(messages: [.user("hi")]) {
            if case .completed(let text) = event { final = text }
        }
        #expect(final == "final answer")
    }

    @Test("対話ツール呼び出しで .inputRequired を発し、ツールは実行しない")
    func emitsInputRequired() async throws {
        let loop = AgentLoop(client: ScriptedClient(askUser: true), model: "mock", tools: ToolSet { RequestUserInputTool() })
        var events: [AgentLoop<ScriptedClient>.Event] = []
        for try await event in loop.run(messages: [.user("weather please")]) { events.append(event) }

        guard case .inputRequired(let question) = events.last else {
            Issue.record("expected inputRequired, got \(events)"); return
        }
        #expect(question == "Which city?")
    }
}
