import Foundation
import Testing
import A2ACore
import A2AClientCore
import A2AServer
import A2AInProcess
import LLMTool
@testable import AgentRuntime

/// Flipped mid-test to take the "network" down without touching the worker.
actor TransportOutage {
    private(set) var isDown = false
    func bringDown() { isDown = true }
}

private struct OutageError: Error, CustomStringConvertible {
    var description: String { "transport is down" }
}

/// Wraps a working transport and fails re-reads once the outage is switched on.
///
/// Sending still works, so a delegation can be started and only then lose its connection — which
/// is the case where a stale snapshot is indistinguishable from a fresh reading.
struct OutageTransport: A2ATransport {
    let inner: any A2ATransport
    let outage: TransportOutage

    private func guardOutage() async throws {
        if await outage.isDown { throw OutageError() }
    }

    func sendMessage(_ request: SendMessageRequest) async throws -> SendMessageResponse {
        try await inner.sendMessage(request)
    }
    func sendStreamingMessage(_ request: SendMessageRequest) async throws -> AsyncThrowingStream<StreamResponse, Error> {
        try await inner.sendStreamingMessage(request)
    }
    func getTask(_ request: GetTaskRequest) async throws -> A2ATask {
        try await guardOutage()
        return try await inner.getTask(request)
    }
    func listTasks(_ request: ListTasksRequest) async throws -> ListTasksResponse {
        try await inner.listTasks(request)
    }
    func cancelTask(_ request: CancelTaskRequest) async throws -> A2ATask {
        try await guardOutage()
        return try await inner.cancelTask(request)
    }
    func subscribeToTask(_ request: SubscribeToTaskRequest) async throws -> AsyncThrowingStream<StreamResponse, Error> {
        try await inner.subscribeToTask(request)
    }
    func createTaskPushNotificationConfig(_ config: TaskPushNotificationConfig) async throws -> TaskPushNotificationConfig {
        try await inner.createTaskPushNotificationConfig(config)
    }
    func getTaskPushNotificationConfig(_ request: GetTaskPushNotificationConfigRequest) async throws -> TaskPushNotificationConfig {
        try await inner.getTaskPushNotificationConfig(request)
    }
    func listTaskPushNotificationConfigs(_ request: ListTaskPushNotificationConfigsRequest) async throws -> ListTaskPushNotificationConfigsResponse {
        try await inner.listTaskPushNotificationConfigs(request)
    }
    func deleteTaskPushNotificationConfig(_ request: DeleteTaskPushNotificationConfigRequest) async throws {
        try await inner.deleteTaskPushNotificationConfig(request)
    }
    func getExtendedAgentCard(_ request: GetExtendedAgentCardRequest) async throws -> AgentCard {
        try await inner.getExtendedAgentCard(request)
    }
}

/// An in-process client whose re-reads can be cut off.
func makeOutageClient(handler: any RequestHandler, outage: TransportOutage) -> A2AClient {
    let base = A2AClient.inProcess(handler: handler)
    return A2AClient(
        transport: OutageTransport(inner: base.transport, outage: outage),
        http: HTTPClient(configuration: base.configuration),
        configuration: base.configuration
    )
}

/// Delivery with every mechanism off, so nothing races the assertions.
private let silentDelivery = BackgroundDelivery(subscribe: false, push: false, pollInterval: nil)

@Suite("Stale readings are never presented as current state")
struct StaleReadingTests {

    private func makeRegistry(_ outage: TransportOutage, gate: TestGate) async -> AgentConnectionRegistry {
        let registry = AgentConnectionRegistry()
        let card = backgroundTestCard("researcher")
        let handler = DefaultRequestHandler(agentCard: card, executor: GatedWorker(gate: gate))
        await registry.register(card: card, client: makeOutageClient(handler: handler, outage: outage))
        return registry
    }

    @Test("check_task: 再読み取りが失敗したら、古いスナップショットを現在の状態として返さない", .timeLimit(.minutes(1)))
    func checkTaskToolReportsUnreadableInsteadOfStale() async throws {
        let gate = TestGate()
        let outage = TransportOutage()
        let registry = await makeRegistry(outage, gate: gate)

        let handle = try await registry.delegateAsync(to: "researcher", text: "調べて", delivery: silentDelivery)
        let taskId = try #require(handle.taskId)

        await outage.bringDown()

        let tool = CheckTaskTool(registry: registry)
        let result = try await tool.execute(with: Data(#"{"task_id":"\#(taskId.rawValue)"}"#.utf8))

        // Before the fix this came back as .text("Task … is still working. Check again later.") —
        // a reading that was never taken, worded as if it had been.
        #expect(result.isError)
        #expect(result.stringValue.contains("transport is down"))

        await gate.release()
    }

    @Test("checkTask は読めなかった読み取りを stale として返す", .timeLimit(.minutes(1)))
    func checkTaskCarriesStaleness() async throws {
        let gate = TestGate()
        let outage = TransportOutage()
        let registry = await makeRegistry(outage, gate: gate)

        let handle = try await registry.delegateAsync(to: "researcher", text: "調べて", delivery: silentDelivery)
        let taskId = try #require(handle.taskId)

        let fresh = try await registry.checkTask(taskId)
        #expect(fresh.freshness == .fresh)

        await outage.bringDown()
        let stale = try await registry.checkTask(taskId)
        guard case .stale(let reason) = stale.freshness else {
            Issue.record("expected a stale reading, got \(stale.freshness)")
            return
        }
        #expect(reason.contains("transport is down"))

        await gate.release()
    }

    @Test("listRunningTasks も読めなかったタスクを stale として返す", .timeLimit(.minutes(1)))
    func listRunningTasksCarriesStaleness() async throws {
        let gate = TestGate()
        let outage = TransportOutage()
        let registry = await makeRegistry(outage, gate: gate)

        _ = try await registry.delegateAsync(to: "researcher", text: "調べて", delivery: silentDelivery)
        await outage.bringDown()

        let running = await registry.listRunningTasks()
        #expect(running.count == 1)
        #expect(running.first?.freshness != .fresh)

        await gate.release()
    }

    @Test("cancel は「止めるものが無かった」と「止められなかった」を区別する", .timeLimit(.minutes(1)))
    func cancelDistinguishesFailureFromNothingToDo() async throws {
        let gate = TestGate()
        let outage = TransportOutage()
        let registry = await makeRegistry(outage, gate: gate)

        _ = try await registry.delegateAsync(to: "researcher", text: "調べて", delivery: silentDelivery)
        await outage.bringDown()

        let outcome = await registry.cancel("researcher")
        #expect(outcome.didFail)
        #expect(outcome.failures.contains { $0.contains("transport is down") })

        // Nothing registered under that name: no failure, nothing cancelled.
        let unknown = await registry.cancel("ghost")
        #expect(!unknown.didFail)
        #expect(unknown.lastState == nil)

        await gate.release()
    }
}
