import LLMAgentStep
import LLMTool
import LLMClient
import Foundation
import Testing
@testable import AgentLoopKit

private enum MockError: Error { case unused }

/// Records the transcript handed to a transcript-aware tool at execution time.
private actor TranscriptStore {
    var transcripts: [[LLMMessage]] = []
    func record(_ transcript: [LLMMessage]) { transcripts.append(transcript) }
}

private struct ProbeTranscriptTool: TranscriptAwareTool {
    let store: TranscriptStore

    var toolName: String { "probe" }
    var toolDescription: String { "records transcript" }
    var inputSchema: JSONSchema { .object(properties: ["x": .string()], required: []) }

    func execute(with argumentsData: Data) async throws -> ToolResult { .text("plain") }

    func execute(with argumentsData: Data, transcript: [LLMMessage]) async throws -> ToolResult {
        await store.record(transcript)
        return .text("done")
    }
}

/// Calls search, then probe, then finishes — so probe runs with a real prior result in scope.
private struct TwoStepClient: AgentCapableClient {
    typealias Model = String

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        let toolResultCount = messages.filter { !$0.toolResults.isEmpty }.count
        let usage = TokenUsage(inputTokens: 0, outputTokens: 0)
        switch toolResultCount {
        case 0:
            return LLMResponse(
                content: [.toolUse(id: "s1", name: "search", input: Data("{}".utf8))],
                model: "mock", usage: usage, stopReason: .toolUse
            )
        case 1:
            return LLMResponse(
                content: [.toolUse(id: "p1", name: "probe", input: Data("{}".utf8))],
                model: "mock", usage: usage, stopReason: .toolUse
            )
        default:
            return LLMResponse(content: [.text("done")], model: "mock", usage: usage, stopReason: .endTurn)
        }
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

@Suite("AgentLoop の transcript 供給")
struct TranscriptSupplyTests {

    @Test("同一 run 内で先に完了したツール結果が transcript に含まれる")
    func suppliesLiveTranscriptIncludingPriorToolResults() async throws {
        let store = TranscriptStore()
        let tools = ToolSet {
            DynamicTool("search", description: "search") {
                JSONSchema.string(description: "q").named("q")
            } handler: { _ in .text(#"{"recipes":[{"id":"207505149046817824"}]}"#) }
            ProbeTranscriptTool(store: store)
        }
        let loop = AgentLoop(client: TwoStepClient(), model: "mock", tools: tools)
        try await loop.run(messages: [.user("鶏むね肉")]) { _ in }

        let transcript = try #require(await store.transcripts.first)
        // At probe time: user, assistant(search), the search result, assistant(probe).
        #expect(transcript.count == 4)
        // The earlier tool's real output is visible, not a placeholder.
        let toolResultMessages = transcript.filter { !$0.toolResults.isEmpty }
        #expect(toolResultMessages.count == 1)
        #expect("\(toolResultMessages[0].contents)".contains("207505149046817824"))
        // The tail is the still-unresolved call to probe itself; dropping it is the tool's job.
        let last = try #require(transcript.last)
        #expect(last.role == .assistant)
        #expect("\(last.contents)".contains("probe"))
    }
}
