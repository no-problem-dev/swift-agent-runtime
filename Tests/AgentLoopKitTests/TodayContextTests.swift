import Foundation
import Testing
@testable import AgentLoopKit

/// executeAgentStep が受け取った systemPrompt を記録する probe クライアント。
private actor PromptRecorder {
    var prompts: [String?] = []
    func record(_ prompt: String?) { prompts.append(prompt) }
}

private struct PromptCapturingClient: AgentCapableClient {
    typealias Model = String
    let recorder: PromptRecorder

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?) async throws -> LLMResponse {
        await recorder.record(systemPrompt?.render())
        return LLMResponse(content: [.text("ok")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { fatalError("unused") }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { fatalError("unused") }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { fatalError("unused") }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { fatalError("unused") }
}

@Suite("Today context grounding (全エージェント共通の日付前置)")
struct TodayContextTests {

    @Test("システムプロンプトの先頭に必ず今日の日付が入る")
    func prependsTodayToExistingPrompt() async throws {
        let recorder = PromptRecorder()
        let loop = AgentLoop(
            client: PromptCapturingClient(recorder: recorder),
            model: "mock",
            systemPrompt: "You are a researcher."
        )
        try await loop.run(messages: [.user("hi")]) { _ in }

        let prompt = try #require(await recorder.prompts.first ?? nil)
        let dateIndex = try #require(prompt.range(of: "Today's date is "))
        let roleIndex = try #require(prompt.range(of: "You are a researcher."))
        #expect(dateIndex.lowerBound < roleIndex.lowerBound)
    }

    @Test("システムプロンプトが nil でも日付だけは入る")
    func injectsTodayWhenPromptIsNil() async throws {
        let recorder = PromptRecorder()
        let loop = AgentLoop(client: PromptCapturingClient(recorder: recorder), model: "mock")
        try await loop.run(messages: [.user("hi")]) { _ in }

        let prompt = try #require(await recorder.prompts.first ?? nil)
        #expect(prompt.contains("Today's date is "))
    }

    @Test("日付行のフォーマットは yyyy-MM-dd (曜日)")
    func todayLineFormat() {
        let line = AgentLoop<PromptCapturingClient>.todayContext(now: Date(timeIntervalSince1970: 1_780_000_000))
        #expect(line.range(of: #"^Today's date is \d{4}-\d{2}-\d{2} \([A-Za-z]+\)\.$"#, options: .regularExpression) != nil)
    }
}
