import LLMClient
import LLMTool
import Foundation

/// swift-llm-client の `executeAgentStep` + `ToolSet` だけで動くツール実行ループ。
///
/// `run(messages:onEvent:)` は内部 Task を立てず呼び出し元のタスクで実行するため、
/// 親タスクのキャンセルがツリーで伝播する。ストリームが要る場合のみ `events(messages:)` を使う。
public struct AgentLoop<Client: AgentCapableClient>: Sendable where Client.Model: Sendable {

    public enum Event: Sendable {
        case thinking(String)
        case toolCall(id: String, name: String)
        case toolResult(name: String, output: String, isError: Bool)
        case inputRequired(question: String)
        case completed(text: String)
        /// LLM 1 ステップ分のトークン使用量（コスト計測用）。
        case usage(TokenUsage, model: String)
    }

    private let client: Client
    private let model: Client.Model
    private let tools: ToolSet
    private let systemPrompt: SystemPrompt?
    private let maxSteps: Int
    private let parallelToolExecution: Bool
    private let maxTokens: Int?

    public init(
        client: Client,
        model: Client.Model,
        tools: ToolSet = ToolSet {},
        systemPrompt: SystemPrompt? = nil,
        maxSteps: Int = 12,
        parallelToolExecution: Bool = true,
        maxTokens: Int? = nil
    ) {
        self.client = client
        self.model = model
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.maxSteps = maxSteps
        self.parallelToolExecution = parallelToolExecution
        self.maxTokens = maxTokens
    }

    /// ループを実行し、ツール呼び出し・結果・最終 assistant 応答まで含む全トランスクリプトを返す。
    /// 返り値をそのまま次ターンの履歴に使うと、委譲とその結果が文脈として引き継がれる。
    @discardableResult
    public func run(messages initial: [LLMMessage], onEvent: (Event) async throws -> Void) async throws -> [LLMMessage] {
        var messages = initial
        for _ in 0..<maxSteps {
            try Task.checkCancellation()

            let response = try await client.executeAgentStep(
                messages: messages,
                model: model,
                systemPrompt: systemPrompt,
                tools: tools,
                toolChoice: tools.isEmpty ? .disabled : .auto,
                responseSchema: nil,
                thinkingMode: .disabled,
                reasoningEffort: nil,
                maxTokens: maxTokens
            )

            try await onEvent(.usage(response.usage, model: response.model))

            var toolUses: [(id: String, name: String, input: Data)] = []
            var text = ""
            for block in response.content {
                switch block {
                case .text(let value): text += value
                case .toolUse(let id, let name, let input): toolUses.append((id, name, input))
                default: break
                }
            }

            if toolUses.isEmpty {
                try await onEvent(.completed(text: text))
                messages.append(.assistant(text))
                return messages
            }

            if !text.isEmpty {
                try await onEvent(.thinking(text))
            }
            messages.append(.toolUses(toolUses.map { (id: $0.id, name: $0.name, input: $0.input) }))

            // 対話ツールは実行せず中断し、入力要求として返す（A2A input-required へ写像）。
            if let ask = toolUses.first(where: { tools.tool(named: $0.name) is any InteractiveRuntimeTool }),
               let interactive = tools.tool(named: ask.name) as? any InteractiveRuntimeTool {
                try await onEvent(.inputRequired(question: interactive.question(from: ask.input)))
                return messages
            }

            for use in toolUses {
                try await onEvent(.toolCall(id: use.id, name: use.name))
            }

            // 複数ツールは子タスクで並列実行し、結果を呼び出し順に整列する。
            let executed: [ToolResult]
            if parallelToolExecution, toolUses.count > 1 {
                let tools = self.tools
                executed = try await withThrowingTaskGroup(of: (Int, ToolResult).self) { group in
                    for (index, use) in toolUses.enumerated() {
                        group.addTask {
                            do {
                                return (index, try await tools.execute(toolNamed: use.name, with: use.input))
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
                        sequential.append(try await tools.execute(toolNamed: use.name, with: use.input))
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
                try await onEvent(.toolResult(name: use.name, output: result.stringValue, isError: result.isError))
            }
            messages.append(.toolResults(results))
        }
        try await onEvent(.completed(text: ""))
        return messages
    }

    public func events(messages: [LLMMessage]) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(messages: messages) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
