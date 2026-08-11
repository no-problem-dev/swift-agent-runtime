import Foundation
import Testing
import LLMClient
import LLMTool
import LLMAgentStep
@testable import AgentRuntime

private enum UnusedError: Error { case notNeeded }

/// Watches the model steps a host actually starts, and which of them were cancelled.
private actor RunProbe {
    private(set) var entries = 0
    private(set) var cancellations = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entries += 1
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func markCancelled() { cancellations += 1 }
    /// Returns once this many model steps have begun, so nothing has to be timed.
    func waitForEntries(_ count: Int) async {
        while entries < count {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

/// Hangs inside the model step until cancelled, recording both facts.
private struct HangingHostClient: AgentCapableClient {
    typealias Model = String
    let probe: RunProbe

    func executeAgentStep(messages: [LLMMessage], model: String, systemPrompt: SystemPrompt?, tools: ToolSet, toolChoice: ToolChoice?, responseSchema: JSONSchema?, thinkingMode: ThinkingMode, reasoningEffort: ReasoningEffort?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> LLMResponse {
        await probe.enter()
        do {
            try await Task.sleep(for: .seconds(2))
        } catch {
            await probe.markCancelled()
            throw error
        }
        return LLMResponse(content: [.text("done")], model: "mock", usage: TokenUsage(inputTokens: 0, outputTokens: 0), stopReason: .endTurn)
    }
    func generateWithUsage<T: StructuredProtocol>(input: LLMInput, model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw UnusedError.notNeeded }
    func generateWithUsage<T: StructuredProtocol>(messages: [LLMMessage], model: String, options: GenerationOptions) async throws -> GenerationResult<T> { throw UnusedError.notNeeded }
    func planToolCalls(prompt: String, model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw UnusedError.notNeeded }
    func planToolCalls(messages: [LLMMessage], model: String, tools: ToolSet, toolChoice: ToolChoice?, systemPrompt: SystemPrompt?, temperature: Double?, maxTokens: Int?, cachePolicy: PromptCachePolicy) async throws -> ToolCallResponse { throw UnusedError.notNeeded }
}

private func makeHost(_ probe: RunProbe) -> HostAgent<HangingHostClient> {
    HostAgent(client: HangingHostClient(probe: probe), model: "mock", registry: AgentConnectionRegistry(), maxSteps: 1)
}

@Suite("HostAgent turn lifecycle")
struct TurnLifecycleTests {

    @Test("重なった run のあとでも cancel() は最初の run に届く", .timeLimit(.minutes(1)))
    func cancelReachesTheFirstRun() async throws {
        let probe = RunProbe()
        let host = makeHost(probe)

        let first = Task { try await host.run("one") }
        await probe.waitForEntries(1)

        // The second call used to take over the run handle, and its `defer` then cleared it.
        let second = Task { try await host.run("two") }
        try? await Task.sleep(for: .milliseconds(150))

        await host.cancel()

        var firstResult: String?
        do { firstResult = try await first.value } catch { /* cancelled, as it should be */ }
        #expect(firstResult == nil, "the first run outlived cancel() and returned \(firstResult ?? "")")
        #expect(await probe.cancellations >= 1)

        second.cancel()
        _ = try? await second.value
    }

    @Test("進行中のターンに重なる run は turnAlreadyRunning で拒否される", .timeLimit(.minutes(1)))
    func overlappingRunIsRefused() async throws {
        let probe = RunProbe()
        let host = makeHost(probe)

        let first = Task { try await host.run("one") }
        await probe.waitForEntries(1)
        #expect(await host.isRunningTurn)

        await #expect(throws: HostAgentError.turnAlreadyRunning) { _ = try await host.run("two") }
        // Refusing must not disturb the turn that is running.
        #expect(await probe.entries == 1)
        #expect(await host.isRunningTurn)

        await host.cancel()
        _ = try? await first.value
        #expect(!(await host.isRunningTurn))
    }

    @Test("終わったターンは登録を解放し、次の run は普通に通る", .timeLimit(.minutes(1)))
    func finishedTurnReleasesTheRegistration() async throws {
        let probe = RunProbe()
        let host = makeHost(probe)

        let first = Task { try await host.run("one") }
        await probe.waitForEntries(1)
        await host.cancel()
        _ = try? await first.value

        // The turn is over, so the next one is allowed — and is itself cancellable.
        let second = Task { try await host.run("two") }
        await probe.waitForEntries(2)
        #expect(await host.isRunningTurn)
        await host.cancel()
        await #expect(throws: (any Error).self) { _ = try await second.value }
        #expect(await probe.cancellations == 2)
    }

    @Test("stream ターン中の run は同時に走らず、cancel() は stream ターンを止める", .timeLimit(.minutes(1)))
    func cancelReachesStreamTurn() async throws {
        let probe = RunProbe()
        let host = makeHost(probe)

        let streamed = Task { for try await _ in await host.stream("one") {} }
        await probe.waitForEntries(1)

        // A turn is already in flight, so this must not start a second one alongside it.
        await #expect(throws: (any Error).self) { _ = try await host.run("two") }

        await host.cancel()
        await #expect(throws: (any Error).self) { try await streamed.value }
        #expect(await probe.entries == 1, "a second model step ran alongside the first")
    }
}
