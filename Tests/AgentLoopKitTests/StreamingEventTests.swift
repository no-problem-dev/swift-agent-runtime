import LLMAgentStep
import LLMTool
import LLMClient
import Foundation
import Testing
@testable import AgentLoopKit

private enum MockError: Error { case unused }

/// streamAgentStep を実装した scripted クライアント。
/// 1 ステップ目: テキストデルタ 2 つ + toolUse、2 ステップ目: テキストデルタ 1 つで完了。
private struct StreamingScriptedClient: AgentCapableClient {
    typealias Model = String

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        Issue.record("streamAgentStep should be used"); throw MockError.unused
    }

    func streamAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) -> AsyncThrowingStream<StreamingAgentEvent, Error> {
        let isFirstStep = !messages.contains { $0.role == .assistant }
        return AsyncThrowingStream { continuation in
            if isFirstStep {
                continuation.yield(.delta(.textDelta("確認")))
                continuation.yield(.delta(.textDelta("します")))
                continuation.yield(.completed(LLMResponse(
                    content: [.text("確認します"), .toolUse(id: "t1", name: "noop", input: Data("{}".utf8))],
                    model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .toolUse
                )))
            } else {
                continuation.yield(.delta(.textDelta("完了")))
                continuation.yield(.completed(LLMResponse(
                    content: [.text("完了")],
                    model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn
                )))
            }
            continuation.finish()
        }
    }

    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

/// 非ストリーミング（executeAgentStep のみ実装 = デフォルトの streamAgentStep）クライアント。
private struct NonStreamingClient: AgentCapableClient {
    typealias Model = String

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        LLMResponse(content: [.text("final answer")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

/// streamAgentStep が受け取った thinkingMode を記録する probe クライアント。
private actor ThinkingModeRecorder {
    var modes: [ThinkingMode] = []
    func record(_ mode: ThinkingMode) { modes.append(mode) }
}

private struct ThinkingModeCapturingClient: AgentCapableClient {
    typealias Model = String
    let recorder: ThinkingModeRecorder

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        await recorder.record(thinkingMode)
        return LLMResponse(content: [.text("ok")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

@Suite("AgentLoop streaming events")
struct StreamingEventTests {

    private var noopTool: ToolSet {
        ToolSet {
            DynamicTool("noop", description: "no-op") {
                JSONSchema.string(description: "ignored").named("x")
            } handler: { _ in .text("done") }
        }
    }

    @Test("ストリーミングクライアントのデルタを到着順に転送し、合成デルタは追加しない")
    func forwardsDeltasWithoutDuplication() async throws {
        let loop = AgentLoop(client: StreamingScriptedClient(), model: "mock", tools: noopTool)
        var events: [AgentEvent] = []
        try await loop.run(messages: [.user("hi")]) { events.append(AgentEvent($0)) }

        var deltas: [String] = []
        var sawToolCall = false
        var completedText: String?
        for event in events {
            switch event {
            case .textDelta(let d): deltas.append(d)
            case .toolCall(let id, let name, _):
                sawToolCall = true
                #expect(id == "t1")
                #expect(name == "noop")
            case .completed(let text): completedText = text
            default: break
            }
        }
        // ステップ 1 のデルタ 2 つ + ステップ 2 のデルタ 1 つ。全文の重複 emit なし
        #expect(deltas == ["確認", "します", "完了"])
        #expect(sawToolCall)
        #expect(completedText == "完了")

        // デルタ → toolCall → 次ステップのデルタ → completed の順序
        let firstDeltaIndex = try #require(events.firstIndex { if case .textDelta = $0 { true } else { false } })
        let toolCallIndex = try #require(events.firstIndex { if case .toolCall = $0 { true } else { false } })
        let lastDeltaIndex = try #require(events.lastIndex { if case .textDelta = $0 { true } else { false } })
        #expect(firstDeltaIndex < toolCallIndex)
        #expect(toolCallIndex < lastDeltaIndex)
    }

    @Test("非ストリーミングクライアントは全文 1 デルタが合成されてから completed が届く")
    func synthesizesSingleDeltaForNonStreamingClient() async throws {
        let loop = AgentLoop(client: NonStreamingClient(), model: "mock")
        var events: [AgentEvent] = []
        try await loop.run(messages: [.user("hi")]) { events.append(AgentEvent($0)) }

        guard events.count == 2,
              case .textDelta(let delta) = events[0],
              case .completed(let text) = events[1] else {
            Issue.record("expected [textDelta, completed], got \(events)")
            return
        }
        #expect(delta == "final answer")
        #expect(text == "final answer")
    }

    @Test("thinkingMode は指定値がそのままステップに渡る（既定 .disabled）")
    func propagatesThinkingMode() async throws {
        let recorder = ThinkingModeRecorder()
        let defaultLoop = AgentLoop(client: ThinkingModeCapturingClient(recorder: recorder), model: "mock")
        try await defaultLoop.run(messages: [.user("hi")]) { _ in }
        #expect(await recorder.modes == [.disabled])

        let adaptiveRecorder = ThinkingModeRecorder()
        let adaptiveLoop = AgentLoop(
            client: ThinkingModeCapturingClient(recorder: adaptiveRecorder),
            model: "mock",
            thinkingMode: .adaptive
        )
        try await adaptiveLoop.run(messages: [.user("hi")]) { _ in }
        #expect(await adaptiveRecorder.modes == [.adaptive])
    }
}
