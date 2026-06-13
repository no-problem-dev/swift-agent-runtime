import Foundation
import Testing
import ACPCore
@testable import AgentLoopKit

private enum MockError: Error { case unused }

/// Calls one tool, then (once it sees the result) returns the final answer.
private struct OneToolClient: AgentCapableClient {
    typealias Model = String

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        let hasResults = messages.contains { message in
            message.contents.contains { if case .toolResult = $0 { return true } else { return false } }
        }
        if hasResults {
            return LLMResponse(content: [.text("the answer")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
        }
        return LLMResponse(content: [.toolUse(id: "t1", name: "search", input: Data("{}".utf8))], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .toolUse)
    }

    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

private struct SearchTool: Tool {
    var toolName: String { "search" }
    var toolDescription: String { "searches" }
    var inputSchema: JSONSchema { .object(properties: [:]) }
    func execute(with argumentsData: Data) async throws -> ToolResult { .text("found 3 results") }
}

@Suite("ACP projection")
struct ACPProjectionTests {
    @Test("the loop projects steps onto ACP session/update, faithfully and in order")
    func projectsSessionUpdates() async throws {
        let loop = AgentLoop(client: OneToolClient(), model: "mock", tools: ToolSet { SearchTool() })

        var updates: [SessionUpdate] = []
        for try await update in loop.updates(messages: [.user("find")]) {
            updates.append(update)
        }

        // tool_call(search) announced in_progress, correlated by id, with kind + rawInput
        guard case let .toolCall(call)? = updates.first(where: { if case .toolCall = $0 { return true } else { return false } }) else {
            Issue.record("expected a tool_call update; got \(updates)"); return
        }
        #expect(call.toolCallId == ToolCallId("t1"))
        #expect(call.title == "Search")
        #expect(call.kind == .search)
        #expect(call.status == .inProgress)
        #expect(call.rawInput != nil)

        // tool_call_update(t1) completed, same id
        guard case let .toolCallUpdate(update)? = updates.first(where: { if case .toolCallUpdate = $0 { return true } else { return false } }) else {
            Issue.record("expected a tool_call_update; got \(updates)"); return
        }
        #expect(update.toolCallId == ToolCallId("t1"))
        #expect(update.status == .completed)

        // final agent_message_chunk carries the answer
        let finalText = updates.reversed().compactMap { value -> String? in
            if case let .agentMessageChunk(chunk) = value, case let .text(text) = chunk.content { return text.text }
            return nil
        }.first
        #expect(finalText == "the answer")

        // ordering: call → update → message
        let kinds = updates.map { value -> String in
            switch value {
            case .toolCall: "call"
            case .toolCallUpdate: "update"
            case .agentMessageChunk: "msg"
            default: "other"
            }
        }
        #expect(kinds.firstIndex(of: "call")! < kinds.firstIndex(of: "update")!)
        #expect(kinds.firstIndex(of: "update")! < kinds.lastIndex(of: "msg")!)
    }
}
