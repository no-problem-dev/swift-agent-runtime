import Foundation
import Testing
import A2ACore
import A2AServer
import A2AInProcess
import LLMClient
import LLMTool
import LLMAgentStep
@testable import AgentRuntime

private enum UnusedError: Error { case notNeeded }

/// Answers with the size of the conversation it was handed, so a host's memory is observable
/// from the outside: a fresh host says "1", one that kept its history says more.
private struct HistorySizeClient: AgentCapableClient {
    typealias Model = String
    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        LLMResponse(content: [.text("\(messages.count)")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw UnusedError.notNeeded }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw UnusedError.notNeeded }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw UnusedError.notNeeded }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw UnusedError.notNeeded }
}

@Suite("Long-lived collections stay bounded")
struct RetentionTests {

    @Test("完了した委譲は際限なく溜まらない。古いものから落ち、新しいものは取れる", .timeLimit(.minutes(2)))
    func finishedDelegationsAreBounded() async throws {
        let registry = AgentConnectionRegistry()
        await registry.register(card: backgroundTestCard("researcher"), executor: BriefWorker())

        // Comfortably past the retention limit, one delegation after another, as a host that runs
        // for a long time would accumulate them.
        let total = AgentConnectionRegistry.defaultRetainedFinishedTasks + 6
        var ids: [TaskID] = []
        for index in 0..<total {
            let handle = try await registry.delegateAsync(
                to: "researcher", text: "task \(index)",
                delivery: BackgroundDelivery(subscribe: false, push: false, pollInterval: nil)
            )
            let taskId = try #require(handle.taskId)
            _ = try await pollUntilTerminal(registry, taskId)
            ids.append(taskId)
        }

        // The oldest finished delegations have been dropped rather than kept for ever.
        await #expect(throws: AgentRuntimeError.unknownAgent("task \(ids[0].rawValue)")) {
            _ = try await registry.checkTask(ids[0])
        }
        // The recent ones are still fetchable, which is what the retention is for.
        let latest = try await registry.checkTask(ids[total - 1])
        #expect(latest.state == .completed)
        #expect(latest.text.contains("結果"))
    }

    @Test("コンテキストごとのホストは際限なく溜まらない。古いものから落ちる", .timeLimit(.minutes(2)))
    func hostsPerContextAreBounded() async throws {
        let card = backgroundTestCard("orchestrator")
        let executor = HostAgentExecutor {
            HostAgent(client: HistorySizeClient(), model: "mock", registry: AgentConnectionRegistry(), maxSteps: 2)
        }
        let client = A2AClient.inProcess(handler: DefaultRequestHandler(agentCard: card, executor: executor))

        func turn(inContext context: String) async throws -> String {
            let response = try await client.sendMessage(Message(
                messageId: MessageID(UUID().uuidString), role: .user,
                parts: [.text("go")], contextId: ContextID(context)
            ))
            guard case .task(let task) = response else {
                Issue.record("expected a task back")
                return ""
            }
            return task.artifacts.first?.parts.compactMap(\.text).joined() ?? ""
        }

        #expect(try await turn(inContext: "first") == "1")
        // The same context continues its conversation: user, assistant, user.
        #expect(try await turn(inContext: "first") == "3")

        // Enough other contexts to push the first one out.
        for index in 0..<HostAgentExecutor<HistorySizeClient>.defaultRetainedContexts {
            _ = try await turn(inContext: "other-\(index)")
        }

        // Its host was released, so the conversation starts over instead of growing for ever.
        #expect(try await turn(inContext: "first") == "1")
    }
}
