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

/// startWork → 短い作業 → artifact「結果」→ complete。必ず自走完了する（無期限停止しない）。
struct BriefWorker: AgentExecutor {
    var workMillis: UInt64 = 120
    func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.startWork()
        try await Task.sleep(for: .milliseconds(Int(workMillis)))
        await updater.addArtifact([.text("結果")], name: "result")
        try await updater.complete()
    }
    func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {}
}

/// バックグラウンド委譲（A2A returnImmediately + tasks/get ポーリング）のテスト。
/// `.timeLimit` を保険に付け、万一ハングしても 1 分で失敗させる。
@Suite("Background delegation (returnImmediately + checkTask/listRunningTasks)")
struct BackgroundDelegationTests {

    private func pollUntilTerminal(_ registry: AgentConnectionRegistry, _ taskId: TaskID) async throws -> AgentTaskStatus {
        for _ in 0..<200 {
            let status = try await registry.checkTask(taskId)
            if status.state.isTerminal { return status }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MockBGError.timedOut
    }

    @Test("delegateAsync は即ハンドルを返し、背景で完走、checkTask で成果物を取得できる", .timeLimit(.minutes(1)))
    func backgroundDelegationLifecycle() async throws {
        let registry = AgentConnectionRegistry()
        await registry.register(card: backgroundTestCard("researcher"), executor: BriefWorker())

        // 即座にハンドルが返る（完了を待たない）。
        let handle = try await registry.delegateAsync(to: "researcher", text: "調べて")
        let taskId = try #require(handle.taskId)

        // 作業中は実行中として列挙される（120ms 作業 vs 直後の list 呼び出し）。
        let running = await registry.listRunningTasks()
        #expect(running.contains { $0.agentName == "researcher" && $0.taskId == taskId })

        // ポーリングで完了を確認。
        let final = try await pollUntilTerminal(registry, taskId)
        #expect(final.state == .completed)
        #expect(final.text.contains("結果"))

        // 完了後は実行中一覧から消えるが、checkTask は引き続き成果物を返す（追跡保持）。
        let after = await registry.listRunningTasks()
        #expect(after.isEmpty)
        let recheck = try await registry.checkTask(taskId)
        #expect(recheck.text.contains("結果"))
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
        #expect(t1 != t2) // 独立タスク

        // 両方が独立に完走し、それぞれ成果物を取得できる。
        let r1 = try await pollUntilTerminal(registry, t1)
        let r2 = try await pollUntilTerminal(registry, t2)
        #expect(r1.state == .completed && r1.text.contains("結果"))
        #expect(r2.state == .completed && r2.text.contains("結果"))
        let after = await registry.listRunningTasks()
        #expect(after.isEmpty)
    }
}

enum MockBGError: Error { case timedOut }
