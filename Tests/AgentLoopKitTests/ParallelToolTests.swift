import Foundation
import Testing
@testable import AgentLoopKit

private enum MockError: Error { case unused }

/// 同時実行数を追跡し、最大同時数を記録する（並列ならツール実行が重なる）。
private actor ConcurrencyTracker {
    private var current = 0
    private(set) var maxConcurrent = 0
    func enter() { current += 1; maxConcurrent = max(maxConcurrent, current) }
    func exit() { current -= 1 }
}

/// 実行時に enter → 短い sleep（重なり窓を作る）→ exit し、名前を返すツール。
private struct TrackTool: Tool {
    let name: String
    let tracker: ConcurrencyTracker
    var toolName: String { name }
    var toolDescription: String { "concurrency tracking tool" }
    var inputSchema: JSONSchema { .object(properties: [:]) }
    func execute(with argumentsData: Data) async throws -> ToolResult {
        await tracker.enter()
        try? await Task.sleep(for: .milliseconds(50))
        await tracker.exit()
        return .text(name)
    }
}

/// 1 ターン目で 2 つのツールを同時に呼び、結果が返ったら完了する。
private struct TwoToolClient: AgentCapableClient {
    typealias Model = String
    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?) async throws -> LLMResponse {
        let hasResults = messages.contains { message in
            message.contents.contains { if case .toolResult = $0 { return true } else { return false } }
        }
        if hasResults {
            return LLMResponse(content: [.text("done")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
        }
        return LLMResponse(content: [
            .toolUse(id: "a", name: "toolA", input: Data("{}".utf8)),
            .toolUse(id: "b", name: "toolB", input: Data("{}".utf8)),
        ], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .toolUse)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
}

private func makeTools(_ tracker: ConcurrencyTracker) -> ToolSet {
    ToolSet {
        TrackTool(name: "toolA", tracker: tracker)
        TrackTool(name: "toolB", tracker: tracker)
    }
}

@Suite("Parallel tool execution")
struct ParallelToolTests {

    @Test("複数ツールは並列実行される（最大同時数 2）。結果は呼び出し順")
    func parallelOverlaps() async throws {
        let tracker = ConcurrencyTracker()
        let loop = AgentLoop(client: TwoToolClient(), model: "mock", tools: makeTools(tracker))

        var toolResults: [String] = []
        var final: String?
        try await loop.run(messages: [.user("go")]) { event in
            switch event {
            case .toolResult(let name, _, _): toolResults.append(name)
            case .completed(let text): final = text
            default: break
            }
        }

        #expect(final == "done")
        #expect(toolResults == ["toolA", "toolB"])     // 呼び出し順に整列
        #expect(await tracker.maxConcurrent == 2)       // 2 つが同時に走った
    }

    @Test("parallelToolExecution: false なら逐次（最大同時数 1）")
    func sequentialNoOverlap() async throws {
        let tracker = ConcurrencyTracker()
        let loop = AgentLoop(client: TwoToolClient(), model: "mock", tools: makeTools(tracker), parallelToolExecution: false)

        var toolResults: [String] = []
        var final: String?
        try await loop.run(messages: [.user("go")]) { event in
            switch event {
            case .toolResult(let name, _, _): toolResults.append(name)
            case .completed(let text): final = text
            default: break
            }
        }

        #expect(final == "done")
        #expect(toolResults == ["toolA", "toolB"])
        #expect(await tracker.maxConcurrent == 1)       // 重ならない
    }
}
