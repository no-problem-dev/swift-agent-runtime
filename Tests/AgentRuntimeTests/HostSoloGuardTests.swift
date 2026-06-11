import Foundation
import Testing
@testable import AgentRuntime

private enum SoloMockError: Error { case unused }

/// ホストへ渡された tools / systemPrompt を 1 度だけ捕捉する。
private actor Capture {
    var toolNames: [String] = []
    var prompt: String = ""
    func record(toolNames: [String], prompt: String) {
        self.toolNames = toolNames
        self.prompt = prompt
    }
}

/// 受け取った tools / systemPrompt を捕捉し、即座に最終テキストを返すだけのホストクライアント。
private struct CapturingClient: AgentCapableClient {
    typealias Model = String
    let capture: Capture

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        await capture.record(toolNames: tools.toolNames, prompt: systemPrompt?.displayText ?? "")
        return LLMResponse(content: [.text("done")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw SoloMockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw SoloMockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw SoloMockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw SoloMockError.unused }
}

private struct NoopReplyClient: AgentCapableClient {
    typealias Model = String
    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        LLMResponse(content: [.text("ok")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw SoloMockError.unused }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?) async throws -> GenerationResult<T> { throw SoloMockError.unused }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw SoloMockError.unused }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw SoloMockError.unused }
}

private func registerWorker(_ registry: AgentConnectionRegistry, name: String) async {
    let card = AgentCard(
        name: name, description: "worker \(name)",
        supportedInterfaces: [AgentInterface(url: "inprocess://local", protocolBinding: "InProcess")],
        version: "1.0.0", capabilities: AgentCapabilities(streaming: true)
    )
    let executor = LLMAgentExecutor(client: NoopReplyClient(), model: "mock")
    await registry.register(card: card, handler: DefaultRequestHandler(agentCard: card, executor: executor))
}

private let delegationTools: Set<String> = [
    "list_remote_agents", "send_message", "delegate_async", "check_task", "list_running_tasks",
]

@Suite("HostAgent co-agent 0 件ガード")
struct HostSoloGuardTests {

    @Test("フリートが空のとき委譲ツールも delegator プロンプトも注入されない")
    func emptyFleetSuppressesDelegation() async throws {
        let capture = Capture()
        let registry = AgentConnectionRegistry()  // 何も register しない
        let host = HostAgent(client: CapturingClient(capture: capture), model: "mock", registry: registry)

        _ = try await host.run("こんにちは")

        let names = await capture.toolNames
        let prompt = await capture.prompt
        #expect(Set(names).isDisjoint(with: delegationTools))
        #expect(!prompt.contains("expert delegator"))
        #expect(!prompt.contains("list_remote_agents"))
        #expect(prompt.contains("capable assistant"))
    }

    @Test("ワーカーが 1 件でもいれば委譲ツールと delegator プロンプトが注入される")
    func nonEmptyFleetEnablesDelegation() async throws {
        let capture = Capture()
        let registry = AgentConnectionRegistry()
        await registerWorker(registry, name: "researcher")
        let host = HostAgent(client: CapturingClient(capture: capture), model: "mock", registry: registry)

        _ = try await host.run("調査して")

        let names = await capture.toolNames
        let prompt = await capture.prompt
        #expect(delegationTools.isSubset(of: Set(names)))
        #expect(prompt.contains("expert delegator"))
    }
}
