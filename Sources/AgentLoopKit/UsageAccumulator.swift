import LLMClient

/// Sums the per-step usage arriving on a telemetry sink into a turn total.
///
/// The sink is `@Sendable` and fires from whatever task ran the step, so accumulating in a plain
/// variable races. A worker uses this to report what it spent back to its caller.
public actor UsageAccumulator {
    /// The running total, or `nil` until the first step reports usage.
    public private(set) var total: TokenUsage?
    public init() {}
    public func add(_ usage: TokenUsage) { total = total?.adding(usage) ?? usage }
}
