import Foundation
import Testing
import ACPCore
import ACPClient
import LLMClient
import LLMTool
import LLMAgentStep
@testable import AgentRuntime

private enum UnusedError: Error { case notNeeded }

/// Answers with fixed text so a turn always produces something worth persisting.
private struct FixedReplyClient: AgentCapableClient {
    typealias Model = String
    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        LLMResponse(content: [.text("ok")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw UnusedError.notNeeded }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw UnusedError.notNeeded }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw UnusedError.notNeeded }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw UnusedError.notNeeded }
}

/// Takes session updates and refuses everything else — nothing here exercises the other calls.
private struct SinkACPClient: ACPClient {
    func requestPermission(_ request: RequestPermissionRequest) async throws -> RequestPermissionResponse { throw UnusedError.notNeeded }
    func writeTextFile(_ request: WriteTextFileRequest) async throws -> WriteTextFileResponse { throw UnusedError.notNeeded }
    func readTextFile(_ request: ReadTextFileRequest) async throws -> ReadTextFileResponse { throw UnusedError.notNeeded }
    func createTerminal(_ request: CreateTerminalRequest) async throws -> CreateTerminalResponse { throw UnusedError.notNeeded }
    func terminalOutput(_ request: TerminalOutputRequest) async throws -> TerminalOutputResponse { throw UnusedError.notNeeded }
    func releaseTerminal(_ request: ReleaseTerminalRequest) async throws -> ReleaseTerminalResponse { throw UnusedError.notNeeded }
    func waitForTerminalExit(_ request: WaitForTerminalExitRequest) async throws -> WaitForTerminalExitResponse { throw UnusedError.notNeeded }
    func killTerminal(_ request: KillTerminalRequest) async throws -> KillTerminalResponse { throw UnusedError.notNeeded }
    func sessionUpdate(_ notification: SessionNotification) async throws {}
    func ext(_ request: ExtRequest) async throws -> ExtResponse { throw UnusedError.notNeeded }
    func extNotification(_ notification: ExtNotification) async throws {}
}

/// A scratch directory removed when the test ends.
private struct TempDirectory: ~Copyable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-persist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private func makeAgent(host: HostAgent<FixedReplyClient>? = nil) -> HostACPAgent<FixedReplyClient> {
    HostACPAgent(client: SinkACPClient()) {
        host ?? HostAgent(client: FixedReplyClient(), model: "mock", registry: AgentConnectionRegistry())
    }
}

@Suite("Conversation persistence at the ACP boundary")
struct ConversationPersistenceTests {

    @Test("書き込みに失敗したターンは呼び出し元に伝わる（黙って履歴を失わない）", .timeLimit(.minutes(1)))
    func failedPersistIsSurfaced() async throws {
        let temp = try TempDirectory()
        let cwd = temp.url.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let agent = makeAgent()
        let session = try await agent.newSession(NewSessionRequest(cwd: cwd.path))

        // Put a regular file where the working directory was, so nothing can be written into it.
        try FileManager.default.removeItem(at: cwd)
        try Data("not a directory".utf8).write(to: cwd)

        await #expect(throws: (any Error).self) {
            _ = try await agent.prompt(PromptRequest(
                sessionId: session.sessionId,
                prompt: [.text(TextContent(text: "hi"))]
            ))
        }
    }

    @Test("壊れた会話ファイルは「新規セッション」として黙って読み込まれない", .timeLimit(.minutes(1)))
    func unreadableConversationIsNotAFreshSession() async throws {
        let temp = try TempDirectory()
        let cwd = temp.url.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try Data("{ this is not the conversation".utf8)
            .write(to: cwd.appendingPathComponent("conversation.json"))

        let agent = makeAgent()
        await #expect(throws: (any Error).self) {
            _ = try await agent.loadSession(LoadSessionRequest(sessionId: SessionId("work"), cwd: cwd.path))
        }
    }

    @Test("会話ファイルがまだ無いのは正常。空の履歴で読み込める", .timeLimit(.minutes(1)))
    func missingConversationLoadsEmpty() async throws {
        let temp = try TempDirectory()
        let cwd = temp.url.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let host = HostAgent(client: FixedReplyClient(), model: "mock", registry: AgentConnectionRegistry())
        let agent = makeAgent(host: host)
        _ = try await agent.loadSession(LoadSessionRequest(sessionId: SessionId("work"), cwd: cwd.path))
        #expect(await host.messages.isEmpty)
    }

    @Test("書き込めた会話はそのまま読み戻せる（往復）", .timeLimit(.minutes(1)))
    func writtenConversationRoundTrips() async throws {
        let temp = try TempDirectory()
        let cwd = temp.url.appendingPathComponent("work")

        let writer = makeAgent()
        let session = try await writer.newSession(NewSessionRequest(cwd: cwd.path))
        _ = try await writer.prompt(PromptRequest(
            sessionId: session.sessionId,
            prompt: [.text(TextContent(text: "hi"))]
        ))

        let resumed = HostAgent(client: FixedReplyClient(), model: "mock", registry: AgentConnectionRegistry())
        let reader = makeAgent(host: resumed)
        _ = try await reader.loadSession(LoadSessionRequest(sessionId: session.sessionId, cwd: cwd.path))
        #expect(await resumed.messages.count == 2)
    }
}
