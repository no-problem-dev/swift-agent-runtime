import Foundation
import Testing
@testable import AgentRuntime

// MARK: - スクリプト化したモック LLM クライアント

private enum MockError: Error { case unused }

/// `executeAgentStep` で固定のテキスト応答（endTurn）を返すだけのモック。
/// `runAgentText` はツール呼び出しが無いため即 `.finalText` に到達する。
private struct MockClient: AgentCapableClient {
    typealias Model = String
    let replyText: String

    func executeAgentStep(
        messages: [LLMMessage],
        model: String,
        systemPrompt: SystemPrompt?,
        tools: ToolSet,
        toolChoice: ToolChoice?,
        responseSchema: JSONSchema?,
        thinkingMode: ThinkingMode,
        reasoningEffort: ReasoningEffort?,
        maxTokens: Int?,
        cachePolicy: PromptCachePolicy
    ) async throws -> LLMResponse {
        LLMResponse(
            content: [.text(replyText)],
            model: "mock",
            usage: TokenUsage(inputTokens: 0, outputTokens: 0),
            stopReason: .endTurn
        )
    }

    // 以降は runAgentText では未使用のため throw スタブ。
    func generateWithUsage<T: StructuredProtocol>(
        input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?
    ) async throws -> GenerationResult<T> { throw MockError.unused }

    func generateWithUsage<T: StructuredProtocol>(
        messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?
    ) async throws -> GenerationResult<T> { throw MockError.unused }

    func planToolCalls(
        prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy
    ) async throws -> ToolCallResponse { throw MockError.unused }

    func planToolCalls(
        messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy
    ) async throws -> ToolCallResponse { throw MockError.unused }
}

private func makeCard() -> AgentCard {
    AgentCard(
        name: "Echo Worker", description: "returns a fixed reply",
        supportedInterfaces: [AgentInterface(url: "inprocess://local", protocolBinding: "InProcess")],
        version: "1.0.0",
        capabilities: AgentCapabilities(streaming: true)
    )
}

private func userMessage(_ text: String) -> Message {
    Message(messageId: MessageID(UUID().uuidString), role: .user, parts: [.text(text)])
}

@Suite("LLMAgentExecutor")
struct LLMAgentExecutorTests {

    @Test("executor を直接駆動: working → artifact → completed")
    func executeDirectly() async throws {
        let executor = LLMAgentExecutor(client: MockClient(replyText: "done!"), model: "mock")
        let queue = EventQueue()
        let context = RequestContext(
            message: userMessage("go"),
            taskId: TaskID("t1"),
            contextId: ContextID("c1")
        )

        let collected = Task { () -> [StreamResponse] in
            var events: [StreamResponse] = []
            for await event in await queue.tap() { events.append(event) }
            return events
        }
        await Task.yield()

        try await executor.execute(context, eventQueue: queue)
        await queue.close()
        let events = await collected.value

        let states = events.compactMap { event -> TaskState? in
            if case .statusUpdate(let update) = event { return update.status.state }
            return nil
        }
        #expect(states.first == .working)
        #expect(states.last == .completed)

        let artifacts = events.compactMap { event -> Artifact? in
            if case .artifactUpdate(let update) = event { return update.artifact }
            return nil
        }
        #expect(artifacts.count == 1)
        #expect(artifacts.first?.parts.first?.text == "done!")
    }

    @Test("A2AClient.inProcess 経由でワーカーを呼ぶ（別 Task・型直結の end-to-end）")
    func endToEndInProcess() async throws {
        let executor = LLMAgentExecutor(client: MockClient(replyText: "hello from worker"), model: "mock")
        let handler = DefaultRequestHandler(agentCard: makeCard(), executor: executor)
        let client = A2AClient.inProcess(handler: handler)

        let response = try await client.sendMessage(userMessage("hi"))
        guard case .task(let task) = response else { Issue.record("expected task"); return }
        #expect(task.status.state == .completed)
        #expect(task.artifacts.first?.parts.first?.text == "hello from worker")
    }

    @Test("streamMessage でワーカーの working → completed が流れる")
    func endToEndStream() async throws {
        let executor = LLMAgentExecutor(client: MockClient(replyText: "streamed"), model: "mock")
        let handler = DefaultRequestHandler(agentCard: makeCard(), executor: executor)
        let client = A2AClient.inProcess(handler: handler)

        var sawWorking = false
        var sawArtifact = false
        var sawCompleted = false
        for try await event in try await client.streamMessage(userMessage("hi")) {
            switch event {
            case .statusUpdate(let update):
                if update.status.state == .working { sawWorking = true }
                if update.status.state == .completed { sawCompleted = true }
            case .artifactUpdate:
                sawArtifact = true
            default:
                break
            }
        }
        #expect(sawWorking)
        #expect(sawArtifact)
        #expect(sawCompleted)
    }
}
