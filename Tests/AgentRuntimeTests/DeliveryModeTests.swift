import Foundation
import Testing
import A2AServer
import A2AInProcess
@testable import AgentRuntime

/// startWork → working → 少し待って → artifact → complete（モード差を観測できる速度）。
private struct SlowExecutor: AgentExecutor {
    func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()
        try await Task.sleep(for: .milliseconds(30))
        try await updater.updateStatus(.working, message: updater.newAgentMessage([.text("作業中")]))
        try await Task.sleep(for: .milliseconds(30))
        await updater.addArtifact([.text("結果"), ], name: "result")
        try await updater.complete()
    }
    func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {}
}

private func makeClient() -> A2AClient {
    let card = AgentCard(
        name: "w", description: "w",
        supportedInterfaces: [AgentInterface(url: "inprocess://local", protocolBinding: "InProcess")],
        version: "1.0.0", capabilities: AgentCapabilities(streaming: true)
    )
    return A2AClient.inProcess(handler: DefaultRequestHandler(agentCard: card, executor: SlowExecutor()))
}

private func userMessage(_ text: String) -> Message {
    Message(messageId: MessageID(UUID().uuidString), role: .user, parts: [.text(text)])
}

@Suite("DeliveryMode (streaming / blocking / polling)")
struct DeliveryModeTests {

    @Test("streaming: 途中の working を含む複数イベントを受信し completed で終わる")
    func streaming() async throws {
        let client = makeClient()
        var states: [TaskState] = []
        for try await event in client.events(userMessage("go"), mode: .streaming) {
            if case .statusUpdate(let u) = event { states.append(u.status.state) }
            if case .task(let t) = event { states.append(t.status.state) }
        }
        #expect(states.contains(.working))
        #expect(states.last == .completed)
    }

    @Test("blocking: 終端まで待ち、completed が 1 回返る")
    func blocking() async throws {
        let client = makeClient()
        var events: [TaskState] = []
        for try await event in client.events(userMessage("go"), mode: .blocking) {
            if case .task(let t) = event { events.append(t.status.state) }
        }
        #expect(events == [.completed])
    }

    @Test("polling: 即座に非終端を受け、ポーリングで completed まで到達")
    func polling() async throws {
        let client = makeClient()
        var states: [TaskState] = []
        for try await event in client.events(userMessage("go"), mode: .polling, pollInterval: .milliseconds(15)) {
            if case .task(let t) = event { states.append(t.status.state) }
        }
        #expect(!(states.first?.isTerminal ?? true))   // 最初は非終端
        #expect(states.last == .completed)              // 最後は完了
    }
}
