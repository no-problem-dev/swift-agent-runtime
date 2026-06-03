import Foundation
import Testing
@testable import AgentRuntime

// 共通のモック（LLMAgentExecutorTests と同じ方針: 固定テキストを返す）
private enum MockError: Error { case unused }

private struct FixedReplyClient: AgentCapableClient {
    typealias Model = String
    let replyText: String

    func executeAgentStep(
        messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet,
        toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode,
        reasoningEffort: ReasoningEffort?, maxTokens: Int?
    ) async throws -> LLMResponse {
        LLMResponse(content: [.text(replyText)], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw MockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> ToolCallResponse { throw MockError.unused }
}

private func makeWorker(name: String, reply: String) -> (AgentCard, DefaultRequestHandler) {
    let card = AgentCard(
        name: name, description: "worker \(name)",
        supportedInterfaces: [AgentInterface(url: "inprocess://local", protocolBinding: "InProcess")],
        version: "1.0.0",
        capabilities: AgentCapabilities(streaming: true)
    )
    let executor = LLMAgentExecutor(client: FixedReplyClient(replyText: reply), model: "mock")
    return (card, DefaultRequestHandler(agentCard: card, executor: executor))
}

private func makeRegistryWithTwoWorkers() async -> AgentConnectionRegistry {
    let registry = AgentConnectionRegistry()
    let (cardA, handlerA) = makeWorker(name: "alpha", reply: "alpha reply")
    let (cardB, handlerB) = makeWorker(name: "beta", reply: "beta reply")
    await registry.register(card: cardA, handler: handlerA)
    await registry.register(card: cardB, handler: handlerB)
    return registry
}

@Suite("AgentConnectionRegistry & orchestrator tools")
struct AgentConnectionRegistryTests {

    @Test("descriptors は登録済みワーカーを名前順で返す")
    func descriptors() async throws {
        let registry = await makeRegistryWithTwoWorkers()
        let descriptors = await registry.descriptors()
        #expect(descriptors.map(\.name) == ["alpha", "beta"])
    }

    @Test("send は対象ワーカーを駆動し completed のテキストを返す")
    func sendDrivesWorker() async throws {
        let registry = await makeRegistryWithTwoWorkers()
        let outcome = try await registry.send(to: "beta", text: "do it")
        #expect(outcome.agentName == "beta")
        #expect(outcome.state == .completed)
        #expect(outcome.text == "beta reply")
    }

    @Test("未登録エージェントへの send は unknownAgent を投げる")
    func sendUnknownAgent() async throws {
        let registry = AgentConnectionRegistry()
        await #expect(throws: AgentRuntimeError.unknownAgent("ghost")) {
            _ = try await registry.send(to: "ghost", text: "hi")
        }
    }

    @Test("list_agents ツールは JSON で 2 件返す")
    func listAgentsTool() async throws {
        let registry = await makeRegistryWithTwoWorkers()
        let tool = ListRemoteAgentsTool(registry: registry)
        let result = try await tool.execute(with: Data("{}".utf8))

        guard case .json(let data) = result else { Issue.record("expected json"); return }
        let agents = try JSONDecoder().decode([AgentDescriptor].self, from: data)
        #expect(agents.map(\.name) == ["alpha", "beta"])
    }

    @Test("send_message ツールは対象ワーカーの応答テキストを返す")
    func sendMessageTool() async throws {
        let registry = await makeRegistryWithTwoWorkers()
        let tool = SendMessageTool(registry: registry)
        let args = Data(#"{"agent_name":"alpha","message":"go"}"#.utf8)
        let result = try await tool.execute(with: args)

        guard case .text(let text) = result else { Issue.record("expected text"); return }
        #expect(text == "alpha reply")
    }

    @Test("send_message ツールは ToolSet に組み込める")
    func toolsComposeIntoToolSet() async throws {
        let registry = await makeRegistryWithTwoWorkers()
        let tools = ToolSet {
            ListRemoteAgentsTool(registry: registry)
            SendMessageTool(registry: registry)
        }
        #expect(tools.toolNames.sorted() == ["list_remote_agents", "send_message"])
    }
}
