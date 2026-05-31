import LLMClient
import LLMTool
import Foundation

/// ランタイム自前のツール実行ループ。
///
/// swift-llm-client の `AgentCapableClient.executeAgentStep` と `ToolSet` のみに依存し、
/// swift-llm-agent（LLMAgent / LLMAgentSession）には依存しない。MCP などのツールは
/// `ToolSet` 経由でそのまま利用できる。
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

    public init(
        client: Client,
        model: Client.Model,
        tools: ToolSet = ToolSet {},
        systemPrompt: SystemPrompt? = nil,
        maxSteps: Int = 12
    ) {
        self.client = client
        self.model = model
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.maxSteps = maxSteps
    }

    public func run(messages initial: [LLMMessage]) -> AsyncThrowingStream<Event, Error> {
        let client = self.client
        let model = self.model
        let tools = self.tools
        let systemPrompt = self.systemPrompt
        let maxSteps = self.maxSteps

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var messages = initial
                    for _ in 0..<maxSteps {
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
                            continuation.yield(.completed(text: text))
                            continuation.finish()
                            return
                        }

                        if !text.isEmpty {
                            continuation.yield(.thinking(text))
                        }
                        messages.append(.toolUses(toolUses.map { (id: $0.id, name: $0.name, input: $0.input) }))

                        // 対話ツール（InteractiveRuntimeTool）が呼ばれたら、実行せず中断して入力を要求。
                        if let ask = toolUses.first(where: { tools.tool(named: $0.name) is any InteractiveRuntimeTool }),
                           let interactive = tools.tool(named: ask.name) as? any InteractiveRuntimeTool {
                            continuation.yield(.inputRequired(question: interactive.question(from: ask.input)))
                            continuation.finish()
                            return
                        }

                        var results: [(toolCallId: String, name: String, content: ToolResultContent)] = []
                        for use in toolUses {
                            continuation.yield(.toolCall(id: use.id, name: use.name))
                            let result: ToolResult
                            do {
                                result = try await tools.execute(toolNamed: use.name, with: use.input)
                            } catch {
                                result = .error("\(error)")
                            }
                            let content: ToolResultContent = result.isError
                                ? .failure(result.stringValue)
                                : .success(result.stringValue)
                            results.append((toolCallId: use.id, name: use.name, content: content))
                            continuation.yield(.toolResult(name: use.name, output: result.stringValue, isError: result.isError))
                        }
                        messages.append(.toolResults(results))
                    }
                    continuation.yield(.completed(text: ""))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
