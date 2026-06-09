import Foundation
import Testing
import A2ACore
import A2AServer
@testable import AgentRuntime

func backgroundTestCard(_ name: String) -> AgentCard {
    AgentCard(
        name: name, description: name,
        supportedInterfaces: [AgentInterface(url: "inprocess://local", protocolBinding: "InProcess")],
        version: "1.0.0", capabilities: AgentCapabilities(streaming: true)
    )
}

/// テスト制御ゲート。worker は wait() で停止し、release() まで完了しない（決定論的）。
actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func release() { isOpen = true; for w in waiters { w.resume() }; waiters.removeAll() }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// startWork（working を発行）→ gate で停止 → artifact「結果」→ complete。
/// startWork を先に出すので returnImmediately は working スナップショットを即返せる。
struct GatedWorker: AgentExecutor {
    let gate: TestGate
    func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()
        await gate.wait()
        await updater.addArtifact([.text("結果")], name: "result")
        try await updater.complete()
    }
    func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {}
}

/// startWork → 短い作業 → artifact「結果」→ complete。必ず自走完了する。
struct BriefWorker: AgentExecutor {
    func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()
        await updater.addArtifact([.text("結果")], name: "result")
        try await updater.complete()
    }
    func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {}
}

func pollUntilTerminal(_ registry: AgentConnectionRegistry, _ taskId: TaskID) async throws -> AgentTaskStatus {
    for _ in 0..<400 {
        let status = try await registry.checkTask(taskId)
        if status.state.isTerminal { return status }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw MockBGError.timedOut
}

/// バックグラウンド委譲（A2A returnImmediately + tasks/get ポーリング）のテスト。
/// `.timeLimit` を保険に付け、万一ハングしても 1 分で失敗させる。
@Suite("Background delegation (returnImmediately + checkTask/listRunningTasks)")
struct BackgroundDelegationTests {

    @Test("delegateAsync は即ハンドルを返し、完了後も checkTask で成果物を取得できる", .timeLimit(.minutes(1)))
    func backgroundDelegationLifecycle() async throws {
        let registry = AgentConnectionRegistry()
        await registry.register(card: backgroundTestCard("researcher"), executor: BriefWorker())

        let handle = try await registry.delegateAsync(to: "researcher", text: "調べて")
        let taskId = try #require(handle.taskId)

        let final = try await pollUntilTerminal(registry, taskId)
        #expect(final.state == .completed)
        #expect(final.text.contains("結果"))

        // 完了後も追跡は保持され、checkTask は引き続き成果物を返す。
        let recheck = try await registry.checkTask(taskId)
        #expect(recheck.text.contains("結果"))
    }

    @Test("実行中タスクは listRunningTasks に現れ、完了後は消える", .timeLimit(.minutes(1)))
    func listRunningThenEmpties() async throws {
        let gate = TestGate()
        let registry = AgentConnectionRegistry()
        await registry.register(card: backgroundTestCard("researcher"), executor: GatedWorker(gate: gate))

        let handle = try await registry.delegateAsync(to: "researcher", text: "調べて")
        let taskId = try #require(handle.taskId)

        // gate 解放前は確実に実行中（決定論的）。
        let running = await registry.listRunningTasks()
        #expect(running.contains { $0.agentName == "researcher" && $0.taskId == taskId })

        // 解放して完了させると一覧から消える。
        await gate.release()
        _ = try await pollUntilTerminal(registry, taskId)
        let after = await registry.listRunningTasks()
        #expect(after.isEmpty)
    }

    @Test("複数ワーカーへ並列に非ブロッキング委譲できる（独立タスク）", .timeLimit(.minutes(1)))
    func parallelBackgroundDelegation() async throws {
        let registry = AgentConnectionRegistry()
        await registry.register(card: backgroundTestCard("researcher"), executor: BriefWorker())
        await registry.register(card: backgroundTestCard("coder"), executor: BriefWorker())

        let h1 = try await registry.delegateAsync(to: "researcher", text: "A")
        let h2 = try await registry.delegateAsync(to: "coder", text: "B")
        let t1 = try #require(h1.taskId)
        let t2 = try #require(h2.taskId)
        #expect(t1 != t2)

        let r1 = try await pollUntilTerminal(registry, t1)
        let r2 = try await pollUntilTerminal(registry, t2)
        #expect(r1.state == .completed && r1.text.contains("結果"))
        #expect(r2.state == .completed && r2.text.contains("結果"))
    }
}

enum MockBGError: Error { case timedOut }
