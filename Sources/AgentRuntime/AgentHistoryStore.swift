import LLMClient
import Foundation

/// ワーカーエージェントの LLM 会話履歴ストア（公式 ADK の SessionService 相当）。
///
/// `AgentLoop` の transcript — tool call / tool result をネイティブな型のまま含む
/// `[LLMMessage]` — を contextId 単位で保持する。A2A タスク履歴（テキスト化された
/// プロトコル上の記録）から会話を復元すると、過去のツール呼び出しが「assistant の
/// テキスト発話」に劣化し、モデルがそれを模倣してツールを呼ばずテキストで応答する
/// 事故が起きる。履歴はエージェントの私有物としてネイティブのまま持つのが正:
/// 公式サンプルも自サーバー内の InMemorySessionService で同じことをしている。
///
/// プロトコルにしてあるのは保存先の差し替えのため（公式の InMemory → Database と同型）。
/// インメモリ実装はプロセス再起動で消える — 永続化が要る運用になったら実装を足す。
public protocol AgentHistoryStore: Sendable {
    func history(for contextId: String) async -> [LLMMessage]
    func save(_ history: [LLMMessage], for contextId: String) async
}

/// 既定のインメモリ実装（公式 InMemorySessionService 相当）。
public actor InMemoryAgentHistoryStore: AgentHistoryStore {
    private var histories: [String: [LLMMessage]] = [:]

    public init() {}

    public func history(for contextId: String) -> [LLMMessage] {
        histories[contextId] ?? []
    }

    public func save(_ history: [LLMMessage], for contextId: String) {
        histories[contextId] = history
    }
}
