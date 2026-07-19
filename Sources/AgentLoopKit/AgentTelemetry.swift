import LLMClient

/// エージェント実行の**側帯**観測（意味論イベントではないもの）。
///
/// `AgentLoop.Event` は「エージェントが何をしているか」の意味論だけを持つ。コスト計測・
/// デバッグ観測・検証制御はそこに混ぜず、この sink へ流す。消費側はこれを meter / probe 等の
/// 専用シンクへ振り分け、UI 状態ロジックは意味論イベントだけを見ればよくなる。
public enum AgentTelemetry: Sendable {
    /// ターン開始時に組み立てられた最終 system prompt（デバッグ観測）。
    case systemPrompt(rendered: String)
    /// LLM 1 ステップ分のトークン使用量（コスト計測）。
    case usage(TokenUsage, model: String)
    /// 直前の出力が検証フックで無効と判定された（観測。`willRetry` が true なら是正再生成する）。
    /// `AgentLoop` 自身は発火せず、検証フックを持つ `HostAgent` が流す。
    case validationFailed(issues: [String], willRetry: Bool)
}

/// 側帯観測の注入シンク。`AgentLoop` / `HostAgent` の構築・実行時に注入する。
public typealias AgentTelemetrySink = @Sendable (AgentTelemetry) async -> Void
