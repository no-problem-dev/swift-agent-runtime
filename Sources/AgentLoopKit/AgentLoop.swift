import LLMClient
import LLMTool
import LLMAgentStep
import Foundation

/// Runs the model step, executes the tools it asks for, feeds the results back, and repeats.
///
/// `run(messages:onEvent:)` starts no task of its own, so cancelling the calling task cancels the
/// in-flight model step and every running tool. `events(messages:)` wraps the same work in an
/// unstructured task, which does not inherit the caller's cancellation — there, only cancelling
/// the stream stops the loop.
public struct AgentLoop<Client: AgentCapableClient>: Sendable where Client.Model: Sendable {

    /// What the agent is doing. Token counts, rendered prompts and validation outcomes are not
    /// here — those go to the telemetry sink, so UI state can be driven from this stream alone.
    public enum Event: Sendable {
        /// The next chunk of assistant text. Render from these: a step that produced text always
        /// emits it as deltas, even from a provider that cannot stream (the whole step arrives as
        /// one delta), so concatenating deltas never loses text. The text on `completed` repeats
        /// the same content for history and validation — displaying both duplicates it.
        case textDelta(String)
        /// The next chunk of reasoning text. Only arrives when thinking is enabled.
        case thinkingDelta(String)
        /// A tool the model asked to run, about to be executed. `input` is the raw JSON arguments
        /// exactly as the model produced them — neither parsed nor validated by the loop.
        case toolCall(id: String, name: String, input: Data)
        /// A finished tool call. `isError` marks a failure the model is expected to recover from:
        /// the text is fed back as the tool result and the loop continues, it is not thrown.
        case toolResult(id: String, name: String, output: String, isError: Bool)
        /// A tool that needs approval was requested. The loop stopped without running it — and
        /// without running the other tools in the same batch, so no partial work has happened.
        /// Collect the user's decisions and call `run` again with the returned transcript.
        case toolApprovalRequired(id: String, name: String, input: Data, request: ToolApprovalRequest)
        /// The agent asked the user a question and stopped. Resume by calling `run` again with the
        /// returned transcript plus the user's answer as a new message.
        case inputRequired(question: String)
        /// The turn ended. Also emitted with empty text when the step budget ran out, so this
        /// arriving is not by itself proof the model finished what it was asked.
        case completed(text: String)
    }

    private let client: Client
    private let model: Client.Model
    private let tools: ToolSet
    private let systemPrompt: SystemPrompt?
    private let maxSteps: Int
    private let parallelToolExecution: Bool
    private let maxTokens: Int?
    private let cachePolicy: PromptCachePolicy
    private let thinkingMode: ThinkingMode
    private let reasoningEffort: ReasoningEffort?
    private let telemetry: AgentTelemetrySink?

    /// Creates a loop bound to one client, model and tool set.
    ///
    /// - Parameters:
    ///   - client: The LLM client used for every step.
    ///   - model: The model identifier passed to the client.
    ///   - tools: Tools the model may call. Empty by default, which disables tool choice entirely.
    ///   - systemPrompt: Prepended to every step. When `nil`, only the date line is sent.
    ///   - maxSteps: How many model steps one `run` may take. Hitting the limit emits `completed`
    ///     with empty text rather than throwing, so callers must not read that as success.
    ///   - parallelToolExecution: When `true` (the default), all tools requested in one step run
    ///     concurrently in a task group — one child task per call, with no concurrency cap — and
    ///     their results are reordered to match the call order. `false` runs them one at a time.
    ///   - maxTokens: Output token ceiling per step. `nil` uses the model's own default.
    ///   - cachePolicy: Prompt caching for the stable prefix (system prompt and tool schemas).
    ///     Applied to every step.
    ///   - thinkingMode: Extended thinking. `.disabled` by default so no thinking tokens are
    ///     billed. Independent of streaming: text deltas still arrive when disabled.
    ///   - reasoningEffort: Reasoning budget for models that expose one. `nil` leaves it to the
    ///     provider. A level the model does not accept is mapped to the nearest one it does, so
    ///     this does not have to be matched to the model.
    ///   - telemetry: Receives token usage and the rendered system prompt. `nil` observes nothing.
    public init(
        client: Client,
        model: Client.Model,
        tools: ToolSet = ToolSet {},
        systemPrompt: SystemPrompt? = nil,
        maxSteps: Int = 12,
        parallelToolExecution: Bool = true,
        maxTokens: Int? = nil,
        cachePolicy: PromptCachePolicy = .implicit,
        thinkingMode: ThinkingMode = .disabled,
        reasoningEffort: ReasoningEffort? = nil,
        telemetry: AgentTelemetrySink? = nil
    ) {
        self.client = client
        self.model = model
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.maxSteps = maxSteps
        self.parallelToolExecution = parallelToolExecution
        self.maxTokens = maxTokens
        self.cachePolicy = cachePolicy
        self.thinkingMode = thinkingMode
        self.reasoningEffort = reasoningEffort
        self.telemetry = telemetry
    }

    /// The date line that grounds the model past its knowledge cutoff.
    ///
    /// Every agent in the package runs through this loop, so putting the line here is what makes
    /// it impossible for an individual agent to forget it. It is appended last, not prepended —
    /// see `run` for why.
    static func todayContext(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd (EEEE)"
        return "Today's date is \(formatter.string(from: now))."
    }

    /// Runs the loop and returns the full transcript, tool calls and tool results included.
    ///
    /// Pass the returned transcript straight back as `messages` on the next turn and the model
    /// keeps the tool calls it already made as context. The transcript is also how a suspended
    /// turn resumes: when the loop stops on an approval or a question, it returns with the
    /// unresolved tool calls still at the end, and `pendingToolDecisions` resolves them.
    ///
    /// A tool that throws is not propagated — the error is stringified into a failed tool result
    /// and fed back so the model can correct itself. Cancellation, however, is checked before
    /// every step and does propagate.
    ///
    /// - Parameters:
    ///   - initial: The conversation so far, ending with the new user message.
    ///   - pendingToolDecisions: Verdicts for the tool calls left unresolved by a previous run,
    ///     keyed by tool call id. Approved calls execute without re-emitting `toolCall`; denied
    ///     calls are never executed and get a synthetic non-error result telling the model not to
    ///     retry; calls absent from the map execute normally.
    ///   - onEvent: Called in order for every event. Throwing from it aborts the run.
    /// - Returns: The transcript including the final assistant message.
    @discardableResult
    public func run(
        messages initial: [LLMMessage],
        pendingToolDecisions: [String: ToolApprovalDecision] = [:],
        onEvent: (Event) async throws -> Void
    ) async throws -> [LLMMessage] {
        var messages = initial
        // Resuming from an approval stop: settle the unexecuted toolUses left at the end of the
        // transcript. Approved ones run, denied ones get a synthesised decline, and ones with no
        // verdict (the no-approval-needed tools from the same batch) run normally.
        // Approved calls do not re-emit .toolCall — the client already showed them.
        if !pendingToolDecisions.isEmpty,
           let last = messages.last, last.role == .assistant {
            let pendingUses: [(id: String, name: String, input: Data)] = last.contents.compactMap {
                if case .toolUse(let id, let name, let input) = $0 { (id, name, input) } else { nil }
            }
            if !pendingUses.isEmpty {
                var results: [(toolCallId: String, name: String, content: ToolResultContent)] = []
                var turnEnded = false
                for use in pendingUses {
                    if pendingToolDecisions[use.id] == .denied {
                        let payload = ToolApprovalDecision.deniedResultPayload
                        results.append((toolCallId: use.id, name: use.name, content: .success(payload)))
                        try await onEvent(.toolResult(id: use.id, name: use.name, output: payload, isError: false))
                        continue
                    }
                    if pendingToolDecisions[use.id] == nil {
                        try await onEvent(.toolCall(id: use.id, name: use.name, input: use.input))
                    }
                    let result: ToolResult
                    do {
                        // A transcript-aware tool sees the messages as of this moment, including
                        // the trailing unresolved toolUses message — dropping that is its job.
                        result = try await tools.execute(toolNamed: use.name, with: use.input, transcript: messages)
                    } catch {
                        result = .error("\(error)")
                    }
                    let content: ToolResultContent = result.isError
                        ? .failure(result.stringValue)
                        : .success(result.stringValue)
                    results.append((toolCallId: use.id, name: use.name, content: content))
                    try await onEvent(.toolResult(id: use.id, name: use.name, output: result.stringValue, isError: result.isError))
                    if !result.isError, tools.tool(named: use.name) is any TurnEndingTool {
                        turnEnded = true
                    }
                }
                messages.append(.toolResults(results))
                if turnEnded {
                    try await onEvent(.completed(text: ""))
                    return messages
                }
            }
        }
        // The date is evaluated per run, so a session that stays alive past midnight is still
        // right. Tool-supplied instructions go after the caller's prompt, and the date goes last
        // of all: a value that changes daily at the front would invalidate the cached stable
        // prefix every day, so everything mutable is kept at the end.
        let groundedPrompt = SystemPrompt(
            components: (systemPrompt?.components ?? [])
                + tools.systemInstructions.map { .context($0) }
                + [.context(Self.todayContext())],
            metadata: systemPrompt?.metadata
        )
        // Report the assembled prompt once per run, so a debug view can show what was actually sent.
        await telemetry?(.systemPrompt(rendered: groundedPrompt.render()))
        for _ in 0..<maxSteps {
            try Task.checkCancellation()

            // Stream the step, forwarding text and thinking deltas as they arrive.
            // A provider without streaming falls back to a default that yields only .completed.
            var stepResponse: LLMResponse?
            var streamedText = false
            for try await streamEvent in client.streamAgentStep(
                messages: messages,
                model: model,
                systemPrompt: groundedPrompt,
                tools: tools,
                toolChoice: tools.isEmpty ? .disabled : .auto,
                responseSchema: nil,
                thinkingMode: thinkingMode,
                reasoningEffort: reasoningEffort,
                maxTokens: maxTokens,
                cachePolicy: cachePolicy
            ) {
                switch streamEvent {
                case .delta(.textDelta(let delta)):
                    streamedText = true
                    try await onEvent(.textDelta(delta))
                case .delta(.thinkingDelta(let delta)):
                    try await onEvent(.thinkingDelta(delta))
                case .completed(let response):
                    stepResponse = response
                }
            }
            // A stream that ends without .completed is a broken provider; treat it as empty.
            let response = stepResponse ?? LLMResponse(content: [], model: "", usage: .zero, stopReason: nil)

            // Usage is a metric, not something the agent "did", so it goes to telemetry and never
            // into Event. The ACP usage_update is projected from this sink at the ACP boundary.
            await telemetry?(.usage(response.usage, model: response.model))

            var toolUses: [(id: String, name: String, input: Data)] = []
            var text = ""
            for block in response.content {
                switch block {
                case .text(let value): text += value
                case .toolUse(let id, let name, let input): toolUses.append((id, name, input))
                default: break
                }
            }

            // Synthetic delta for non-streaming providers: a step that never emitted one sends its
            // whole text as a single delta, keeping the promise that text always arrives as deltas.
            if !streamedText, !text.isEmpty {
                try await onEvent(.textDelta(text))
            }

            if toolUses.isEmpty {
                try await onEvent(.completed(text: text))
                messages.append(.assistant(text))
                return messages
            }

            messages.append(.toolUses(toolUses.map { (id: $0.id, name: $0.name, input: $0.input) }))

            // An interactive tool is never executed: the loop stops and reports the question.
            if let ask = toolUses.first(where: { tools.tool(named: $0.name) is any InteractiveRuntimeTool }),
               let interactive = tools.tool(named: ask.name) as? any InteractiveRuntimeTool {
                try await onEvent(.inputRequired(question: interactive.question(from: ask.input)))
                return messages
            }

            // A batch containing an approval-requiring tool stops whole, before anything runs.
            // The tools in it that need no approval are held back too: that avoids a
            // half-executed batch, and the resume pre-step settles all of them together.
            var approvals: [(id: String, name: String, input: Data, request: ToolApprovalRequest)] = []
            for use in toolUses {
                if let tool = tools.tool(named: use.name) as? any ApprovalRequiringTool,
                   let request = await tool.approvalRequest(from: use.input) {
                    approvals.append((use.id, use.name, use.input, request))
                }
            }
            if !approvals.isEmpty {
                for pending in approvals {
                    try await onEvent(.toolApprovalRequired(
                        id: pending.id,
                        name: pending.name,
                        input: pending.input,
                        request: pending.request
                    ))
                }
                return messages
            }

            for use in toolUses {
                try await onEvent(.toolCall(id: use.id, name: use.name, input: use.input))
            }

            // Several tools run concurrently — one child task each, no cap — and the results are
            // put back into call order before they reach the model.
            let executed: [ToolResult]
            if parallelToolExecution, toolUses.count > 1 {
                let tools = self.tools
                // Every child gets the same by-value snapshot of the messages, so concurrent
                // transcript-aware tools cannot observe each other's writes.
                let transcript = messages
                executed = try await withThrowingTaskGroup(of: (Int, ToolResult).self) { group in
                    for (index, use) in toolUses.enumerated() {
                        group.addTask {
                            do {
                                return (index, try await tools.execute(toolNamed: use.name, with: use.input, transcript: transcript))
                            } catch {
                                return (index, .error("\(error)"))
                            }
                        }
                    }
                    var collected: [(Int, ToolResult)] = []
                    for try await pair in group { collected.append(pair) }
                    return collected.sorted { $0.0 < $1.0 }.map(\.1)
                }
            } else {
                var sequential: [ToolResult] = []
                for use in toolUses {
                    do {
                        sequential.append(try await tools.execute(toolNamed: use.name, with: use.input, transcript: messages))
                    } catch {
                        sequential.append(.error("\(error)"))
                    }
                }
                executed = sequential
            }

            var results: [(toolCallId: String, name: String, content: ToolResultContent)] = []
            for (use, result) in zip(toolUses, executed) {
                let content: ToolResultContent = result.isError
                    ? .failure(result.stringValue)
                    : .success(result.stringValue)
                results.append((toolCallId: use.id, name: use.name, content: content))
                try await onEvent(.toolResult(id: use.id, name: use.name, output: result.stringValue, isError: result.isError))
            }
            messages.append(.toolResults(results))

            // A turn-ending tool that succeeded finishes the turn without another model step, so
            // the result is never summarised. A failed one falls through and the model retries.
            let turnEnded = zip(toolUses, executed).contains { use, result in
                !result.isError && tools.tool(named: use.name) is any TurnEndingTool
            }
            if turnEnded {
                try await onEvent(.completed(text: text))
                return messages
            }
        }
        try await onEvent(.completed(text: ""))
        return messages
    }

    /// Runs the same loop, delivering events as a stream instead of a callback.
    ///
    /// The work happens in an unstructured task, so unlike `run(messages:onEvent:)` it does not
    /// inherit the calling task's cancellation. Terminating the stream — breaking out of the
    /// `for await`, or letting it deallocate — is what cancels the loop and its in-flight tools.
    public func events(
        messages: [LLMMessage],
        pendingToolDecisions: [String: ToolApprovalDecision] = [:]
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(messages: messages, pendingToolDecisions: pendingToolDecisions) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
