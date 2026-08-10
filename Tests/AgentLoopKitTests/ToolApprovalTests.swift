import LLMAgentStep
import LLMTool
import LLMClient
import Foundation
import Testing

@testable import AgentLoopKit

private enum MockError: Error { case unused }

/// 1 回目に承認必須ツール(+ 任意で承認不要ツール)を呼び、以降は最終テキストを返す。
private struct ApprovalScriptedClient: AgentCapableClient {
    typealias Model = String
    let includePlainTool: Bool

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        if !messages.contains(where: { $0.role == .assistant }) {
            var content: [LLMResponse.ContentBlock] = [
                .toolUse(id: "f1", name: "follow_shops", input: Data(#"{"count":2}"#.utf8)),
            ]
            if includePlainTool {
                content.append(.toolUse(id: "s1", name: "plain_tool", input: Data("{}".utf8)))
            }
            return LLMResponse(content: content, model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .toolUse)
        }
        return LLMResponse(content: [.text("done")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }

    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw MockError.unused }
}

private final class ExecutionRecorder: @unchecked Sendable {
    var executed: [String] = []
}

private struct ConfirmableFollowTool: ApprovalRequiringTool {
    let recorder: ExecutionRecorder
    var toolName: String { "follow_shops" }
    var toolDescription: String { "Follow shops." }
    var inputSchema: JSONSchema { .object(properties: [:], required: []) }

    func execute(with argumentsData: Data) async throws -> ToolResult {
        recorder.executed.append(toolName)
        return .text(#"{"followed":true}"#)
    }

    func approvalRequest(from argumentsData: Data) async -> ToolApprovalRequest? {
        ToolApprovalRequest(summary: "2 店舗をフォローします", details: ["Aストア", "Bストア"])
    }
}

private struct PlainTool: Tool {
    let recorder: ExecutionRecorder
    var toolName: String { "plain_tool" }
    var toolDescription: String { "No approval needed." }
    var inputSchema: JSONSchema { .object(properties: [:], required: []) }

    func execute(with argumentsData: Data) async throws -> ToolResult {
        recorder.executed.append(toolName)
        return .text("ok")
    }
}

@Suite("ApprovalRequiringTool の中断と再開")
struct ToolApprovalTests {
    @Test("承認必須ツールは実行せず中断し .toolApprovalRequired を発する")
    func suspendsBeforeExecution() async throws {
        let recorder = ExecutionRecorder()
        let loop = AgentLoop(
            client: ApprovalScriptedClient(includePlainTool: false),
            model: "mock",
            tools: ToolSet { ConfirmableFollowTool(recorder: recorder) }
        )
        var events: [AgentLoop<ApprovalScriptedClient>.Event] = []
        let transcript = try await loop.run(messages: [.user("フォローして")]) { events.append($0) }

        guard case .toolApprovalRequired(let id, let name, _, let request) = events.last else {
            Issue.record("expected toolApprovalRequired, got \(events)")
            return
        }
        #expect(id == "f1")
        #expect(name == "follow_shops")
        #expect(request.summary == "2 店舗をフォローします")
        #expect(request.details == ["A", "B"].map { "\($0)ストア" })
        // 実行されていない
        #expect(recorder.executed.isEmpty)
        // トランスクリプト末尾は未解決の toolUses(再開の起点)
        #expect(transcript.last?.role == .assistant)
    }

    @Test("承認で再開するとツールを実行し、.toolCall は再発行しない")
    func resumeApprovedExecutes() async throws {
        let recorder = ExecutionRecorder()
        let loop = AgentLoop(
            client: ApprovalScriptedClient(includePlainTool: false),
            model: "mock",
            tools: ToolSet { ConfirmableFollowTool(recorder: recorder) }
        )
        let suspended = try await loop.run(messages: [.user("フォローして")]) { _ in }

        var events: [AgentLoop<ApprovalScriptedClient>.Event] = []
        let transcript = try await loop.run(
            messages: suspended,
            pendingToolDecisions: ["f1": .approved]
        ) { events.append($0) }

        #expect(recorder.executed == ["follow_shops"])
        // .toolCall の再発行なし、.toolResult → .completed の順
        #expect(!events.contains { if case .toolCall = $0 { true } else { false } })
        guard case .toolResult(let id, _, let output, let isError) = events.first else {
            Issue.record("expected toolResult first, got \(events)")
            return
        }
        #expect(id == "f1")
        #expect(output == #"{"followed":true}"#)
        #expect(!isError)
        guard case .completed(let text) = events.last else {
            Issue.record("expected completed, got \(events)")
            return
        }
        #expect(text == "done")
        #expect(transcript.count > suspended.count)
    }

    @Test("拒否で再開すると辞退結果を合成しツールは実行しない")
    func resumeDeniedSynthesizesResult() async throws {
        let recorder = ExecutionRecorder()
        let loop = AgentLoop(
            client: ApprovalScriptedClient(includePlainTool: false),
            model: "mock",
            tools: ToolSet { ConfirmableFollowTool(recorder: recorder) }
        )
        let suspended = try await loop.run(messages: [.user("フォローして")]) { _ in }

        var events: [AgentLoop<ApprovalScriptedClient>.Event] = []
        try await loop.run(
            messages: suspended,
            pendingToolDecisions: ["f1": .denied]
        ) { events.append($0) }

        #expect(recorder.executed.isEmpty)
        guard case .toolResult(_, _, let output, let isError) = events.first else {
            Issue.record("expected toolResult, got \(events)")
            return
        }
        #expect(output.contains("declined"))
        #expect(!isError)
    }

    @Test("同バッチの承認不要ツールも中断され、再開時に通常実行される")
    func mixedBatchSuspendsWhollyAndResumes() async throws {
        let recorder = ExecutionRecorder()
        let loop = AgentLoop(
            client: ApprovalScriptedClient(includePlainTool: true),
            model: "mock",
            tools: ToolSet {
                ConfirmableFollowTool(recorder: recorder)
                PlainTool(recorder: recorder)
            }
        )
        var firstRunEvents: [AgentLoop<ApprovalScriptedClient>.Event] = []
        let suspended = try await loop.run(messages: [.user("フォローして")]) { firstRunEvents.append($0) }
        // 部分実行なし
        #expect(recorder.executed.isEmpty)

        var events: [AgentLoop<ApprovalScriptedClient>.Event] = []
        try await loop.run(
            messages: suspended,
            pendingToolDecisions: ["f1": .approved]
        ) { events.append($0) }

        #expect(Set(recorder.executed) == ["follow_shops", "plain_tool"])
        // 裁定対象外(plain_tool)には .toolCall が発行される
        #expect(events.contains { if case .toolCall(_, let name, _) = $0 { name == "plain_tool" } else { false } })
    }
}
