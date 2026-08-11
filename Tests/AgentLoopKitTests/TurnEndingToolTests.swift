import LLMAgentStep
import LLMTool
import LLMClient
import Foundation
import Testing
@testable import AgentLoopKit

/// Counts model steps, which is how "the turn ended without another step" is asserted.
private actor StepCounter {
    var count = 0
    func increment() -> Int { count += 1; return count }
}

/// Calls the turn-ending tool on the first step, then answers with fixed text.
private struct ToolThenTextClient: AgentCapableClient {
    typealias Model = String
    let counter: StepCounter
    let assistantText: String

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        let step = await counter.increment()
        if step == 1 {
            let input = try JSONEncoder().encode(["a2ui_json": "[]"])
            var content: [LLMResponse.ContentBlock] = []
            if !assistantText.isEmpty { content.append(.text(assistantText)) }
            content.append(.toolUse(id: "t1", name: "send_ui", input: input))
            return LLMResponse(content: content, model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .toolUse)
        }
        return LLMResponse(content: [.text("final answer")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { fatalError("unused") }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { fatalError("unused") }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { fatalError("unused") }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { fatalError("unused") }
}

/// A turn-ending tool that can be made to succeed or fail, to test both branches.
private struct MockTurnEndingTool: TurnEndingTool {
    let fails: Bool
    var toolName: String { "send_ui" }
    var toolDescription: String { "Sends UI to the client." }
    var inputSchema: JSONSchema { .object(properties: ["a2ui_json": .string()], required: ["a2ui_json"]) }
    func execute(with argumentsData: Data) async throws -> ToolResult {
        fails ? .error("boom") : .text("ok")
    }
}

@Suite("TurnEndingTool (skip_summarization 相当)")
struct TurnEndingToolTests {

    @Test("成功結果は追加推論なしでターンを終える")
    func successEndsTurn() async throws {
        let counter = StepCounter()
        let loop = AgentLoop(
            client: ToolThenTextClient(counter: counter, assistantText: "rendering"),
            model: "mock",
            tools: ToolSet { MockTurnEndingTool(fails: false) }
        )
        var events: [AgentLoop<ToolThenTextClient>.Event] = []
        try await loop.run(messages: [.user("show ui")]) { events.append($0) }

        guard case .completed(let text) = events.last else {
            Issue.record("expected completed, got \(events)"); return
        }
        #expect(text == "rendering")
        #expect(await counter.count == 1)
        #expect(events.contains { if case .toolResult(_, let name, _, let isError) = $0 { return name == "send_ui" && !isError } else { return false } })
    }

    @Test("エラー結果はモデルへ返りループが継続する")
    func errorContinuesLoop() async throws {
        let counter = StepCounter()
        let loop = AgentLoop(
            client: ToolThenTextClient(counter: counter, assistantText: ""),
            model: "mock",
            tools: ToolSet { MockTurnEndingTool(fails: true) }
        )
        var events: [AgentLoop<ToolThenTextClient>.Event] = []
        try await loop.run(messages: [.user("show ui")]) { events.append($0) }

        guard case .completed(let text) = events.last else {
            Issue.record("expected completed, got \(events)"); return
        }
        #expect(text == "final answer")
        #expect(await counter.count == 2)
        #expect(events.contains { if case .toolResult(_, let name, _, let isError) = $0 { return name == "send_ui" && isError } else { return false } })
    }
}
