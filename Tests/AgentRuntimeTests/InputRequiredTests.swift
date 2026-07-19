import Foundation
import Testing
import A2AServer
import A2AInProcess
@testable import AgentRuntime

/// 手書きワーカー（langgraph サンプル同型）: 初回ターンは input-required で中断、
/// 同一タスクへの再送（resume）で completed にする。
private struct PausingExecutor: AgentExecutor {
    func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        if context.currentTask == nil {
            try await updater.startWork()
            try await updater.requiresInput(message: updater.makeAgentMessage([.text("Which city?")]))
        } else {
            await updater.addArtifact([.text("Weather for \(context.userInput())")], name: "result")
            try await updater.complete()
        }
    }
    func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {}
}

private func makePausingWorker() -> (AgentCard, DefaultRequestHandler) {
    let card = AgentCard(
        name: "weather", description: "weather worker that asks for a city",
        supportedInterfaces: [AgentInterface(url: "inprocess://local", protocolBinding: "InProcess")],
        version: "1.0.0", capabilities: AgentCapabilities(streaming: true)
    )
    return (card, DefaultRequestHandler(agentCard: card, executor: PausingExecutor()))
}

@Suite("input-required propagation & resume")
struct InputRequiredTests {

    @Test("registry.send: 初回は input-required、同ワーカーへ再送で completed（resume サイクル）")
    func pauseThenResume() async throws {
        let registry = AgentConnectionRegistry()
        let (card, handler) = makePausingWorker()
        await registry.register(card: card, handler: handler)

        // 初回ターン → 中断（input-required）、質問テキストが返る
        let first = try await registry.send(to: "weather", text: "weather please")
        #expect(first.state == .inputRequired)
        #expect(first.text.contains("Which city?"))

        // ユーザー回答を同ワーカーへ再送 → 同一 task が resume して completed
        let second = try await registry.send(to: "weather", text: "Tokyo")
        #expect(second.state == .completed)
        #expect(second.text.contains("Weather for Tokyo"))
    }

    @Test("send_message ツールは input-required を「ユーザーに尋ねる」よう明示ラベルで返す")
    func toolLabelsInputRequired() async throws {
        let registry = AgentConnectionRegistry()
        let (card, handler) = makePausingWorker()
        await registry.register(card: card, handler: handler)

        let tool = SendMessageTool(registry: registry)
        let result = try await tool.execute(with: Data(#"{"agent_name":"weather","message":"weather please"}"#.utf8))

        guard case .text(let text) = result else { Issue.record("expected text"); return }
        #expect(text.contains("needs more input"))
        #expect(text.contains("Which city?"))
    }
}
