import Foundation
import Testing
import A2ACore
import A2AServer
import LLMTool
@testable import AgentRuntime

/// The background delegation tools as the model sees them.
@Suite("Background host tools (delegate_async / check_task / list_running_tasks)")
struct BackgroundToolsTests {

    @Test("delegate_async は即 task_id を含むテキストを返す", .timeLimit(.minutes(1)))
    func delegateAsyncToolReturnsHandle() async throws {
        let registry = AgentConnectionRegistry()
        await registry.register(card: backgroundTestCard("researcher"), executor: BriefWorker())
        let tool = DelegateAsyncTool(registry: registry)
        let result = try await tool.execute(with: Data(#"{"agent_name":"researcher","message":"go"}"#.utf8))
        #expect(!result.isError)
        #expect(result.stringValue.contains("task_id="))
        #expect(result.stringValue.contains("researcher"))
    }

    @Test("delegate→list_running_tasks→check_task の一連が成立する", .timeLimit(.minutes(1)))
    func toolsLifecycle() async throws {
        let gate = TestGate()
        let registry = AgentConnectionRegistry()
        await registry.register(card: backgroundTestCard("researcher"), executor: GatedWorker(gate: gate))

        let handle = try await registry.delegateAsync(to: "researcher", text: "go")
        let taskId = try #require(handle.taskId)

        // Held at the gate, so it is definitely running and must appear in the list.
        let listTool = ListRunningTasksTool(registry: registry)
        let listResult = try await listTool.execute(with: Data("{}".utf8))
        #expect(listResult.stringValue.contains(taskId.rawValue))

        // Release it and poll the check tool until the completed result comes back.
        await gate.release()
        let checkTool = CheckTaskTool(registry: registry)
        let args = Data("{\"task_id\":\"\(taskId.rawValue)\"}".utf8)
        var finalText = ""
        for _ in 0..<400 {
            let r = try await checkTool.execute(with: args)
            if r.stringValue.contains("結果") { finalText = r.stringValue; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(finalText.contains("結果"))

        // Once finished it is no longer listed, though it is still tracked.
        let after = try await listTool.execute(with: Data("{}".utf8))
        #expect(after.stringValue.contains(taskId.rawValue) == false)
    }
}
