import LLMClient
import LLMTool
import Foundation

/// ランタイム自前のツール実行ループ。
///
/// swift-llm-client の `AgentCapableClient.executeAgentStep` と `ToolSet` のみに依存し、
/// swift-llm-agent（LLMAgent / LLMAgentSession）には依存しない。MCP などのツールは
/// `ToolSet` 経由でそのまま利用できる。
///
/// ## 構造化並行性
///
/// 基本 API `run(messages:onEvent:)` は **呼び出し元のタスク内で逐次実行**する（内部 Task を
/// 立てない）。これにより呼び出し元（ワーカー実行や AgentSession）のタスクツリーの一部となり、
/// 親タスクのキャンセルが `Task.checkCancellation()` を通じてループに伝播する。
/// ストリームとして外部へ渡したい場合だけ `events(messages:)` adapter を使う。
///
/// `executeAgentStep` を呼び、応答にツール呼び出しが含まれれば `ToolSet` で実行して結果を
/// 会話に追記し、ツール呼び出しが無くなる（endTurn）まで繰り返す。呼ばれたツールが
/// `InteractiveRuntimeTool` に準拠していれば、実行せずループを止めて `.inputRequired` を
/// 発する（A2A input-required へ写像）。
public struct AgentLoop<Client: AgentCapableClient>: Sendable where Client.Model: Sendable {

    /// ループの 1 イベント。
    public enum Event: Sendable {
        /// ツール呼び出し前の中間テキスト。
        case thinking(String)
        /// ツール呼び出し開始。
        case toolCall(id: String, name: String)
        /// ツール実行結果。
        case toolResult(name: String, output: String, isError: Bool)
        /// ユーザー入力が必要（対話ツールが呼ばれた）。
        case inputRequired(question: String)
        /// ループ完了。最終テキスト。
        case completed(text: String)
    }

    private let client: Client
    private let model: Client.Model
    private let tools: ToolSet
    private let systemPrompt: SystemPrompt?
    private let maxSteps: Int
    private let parallelToolExecution: Bool

    public init(
        client: Client,
        model: Client.Model,
        tools: ToolSet = ToolSet {},
        systemPrompt: SystemPrompt? = nil,
        maxSteps: Int = 12,
        parallelToolExecution: Bool = true
    ) {
        self.client = client
        self.model = model
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.maxSteps = maxSteps
        self.parallelToolExecution = parallelToolExecution
    }

    /// ループを呼び出し元タスク内で実行し、各イベントを `onEvent` へ渡す（構造化）。
    public func run(messages initial: [LLMMessage], onEvent: (Event) async throws -> Void) async throws {
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
                maxTokens: nil
            )

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
                return
            }

            if !text.isEmpty {
                try await onEvent(.thinking(text))
            }
            messages.append(.toolUses(toolUses.map { (id: $0.id, name: $0.name, input: $0.input) }))

            // 対話ツール（InteractiveRuntimeTool）が呼ばれたら、実行せず中断して入力を要求。
            if let ask = toolUses.first(where: { tools.tool(named: $0.name) is any InteractiveRuntimeTool }),
               let interactive = tools.tool(named: ask.name) as? any InteractiveRuntimeTool {
                try await onEvent(.inputRequired(question: interactive.question(from: ask.input)))
                return
            }

            // ツール呼び出し開始イベント（呼び出し順）。
            for use in toolUses {
                try await onEvent(.toolCall(id: use.id, name: use.name))
            }

            // ツール実行。複数かつ許可時は子タスクで並列実行し、結果を呼び出し順に整列する
            // （並列委譲: 1 ターンで複数ワーカーへ send_message した場合などに同時実行）。
            // TaskGroup は run のタスクの子なので、キャンセルはツリーで伝播する。
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

            // 結果イベント + toolResults メッセージ（呼び出し順）。
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
    }

    /// `run` を外部ストリームとして公開する adapter（ストリーム返却のため内部 Task を立てる）。
    /// ループ本体は構造化のまま `run` を使い、ここは「ストリーム境界」だけを担う。
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
