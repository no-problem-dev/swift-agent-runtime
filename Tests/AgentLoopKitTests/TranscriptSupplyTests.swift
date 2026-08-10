import LLMAgentStep
import LLMTool
import LLMClient
import Foundation
import Testing
@testable import AgentLoopKit

private enum MockError: Error { case unused }

/// TranscriptAwareTool が受け取ったトランスクリプトを記録する。
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

/// 1 ステップ目: search ツール → 2 ステップ目: probe ツール → 3 ステップ目: 完了テキスト。
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
        // probe 実行時点: user + assistant(search) + tool(search 結果) + assistant(probe) の 4 件
        #expect(transcript.count == 4)
        // 先に完了した search の結果(本物のデータ)が見える
        let toolResultMessages = transcript.filter { !$0.toolResults.isEmpty }
        #expect(toolResultMessages.count == 1)
        #expect("\(toolResultMessages[0].contents)".contains("207505149046817824"))
        // 末尾は実行中の probe 呼び出しを含む assistant メッセージ(未解決 — 除去はツール側の責務)
        let last = try #require(transcript.last)
        #expect(last.role == .assistant)
        #expect("\(last.contents)".contains("probe"))
    }
}
