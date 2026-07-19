import LLMClient

/// telemetry sink（@Sendable）越しに usage を集計するためのスレッドセーフな蓄積器。
/// ワーカーが自分の総消費量を artifact metadata で呼び出し元へ返す等に使う。
///
/// `AgentTelemetry` が「何を観測させるか」の定義であるのに対し、こちらはその**消費側**。
/// 変更理由が違うのでファイルを分けている。
public actor UsageAccumulator {
    public private(set) var total: TokenUsage?
    public init() {}
    public func add(_ usage: TokenUsage) { total = total?.adding(usage) ?? usage }
}
