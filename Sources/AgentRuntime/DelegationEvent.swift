import A2ACore
import A2AClientCore
import LLMClient

/// ホストがワーカーへ委譲する間に起きる進捗イベント。
///
/// 公式 Python デモではホスト UI が別経路のタスクイベントストリームから進捗を得る。Swift では
/// `AgentConnectionRegistry` に observer を注入し、`send_message` の実行中に逐次流すことで、
/// 上位 UI が委譲レーンのライブ表示・ワーカー usage の集計をできるようにする（ツールの戻り値とは独立）。
/// `id` は 1 回の `send` を一意に識別する委譲 ID。並列に走る同一エージェントへの委譲を
/// UI 側で個別のレーンに相関させるために使う。
public enum DelegationEvent: Sendable {
    /// 委譲を開始した。
    case started(id: String, agent: String, label: String)
    /// ワーカーの A2A ストリームイベント（status/artifact/message）。レーンのライブ更新用。
    case progress(id: String, agent: String, StreamResponse)
    /// ワーカーが消費したトークン使用量（artifact metadata 由来）。コスト集計用。
    case usage(id: String, agent: String, usage: TokenUsage)
    /// 委譲が終端まで完了した（集約テキストと終端状態）。
    case finished(id: String, agent: String, text: String, state: TaskState?)
    /// 委譲が失敗した。
    case failed(id: String, agent: String, error: String)
}

/// 委譲進捗の観測クロージャ。`AgentConnectionRegistry` に注入する。
public typealias DelegationObserver = @Sendable (DelegationEvent) async -> Void
