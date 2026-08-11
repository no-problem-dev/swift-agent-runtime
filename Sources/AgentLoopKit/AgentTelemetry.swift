import LLMClient

/// Cost and debug observations from a run, kept out of the event stream.
///
/// The loop's events describe what the agent is doing; these describe what it cost and what it
/// was actually sent. Splitting them means UI state can be driven from events alone, and meters
/// and debug views subscribe here without the two vocabularies growing into each other.
public enum AgentTelemetry: Sendable {
    /// The fully assembled system prompt for the turn, including anything the tools contributed
    /// and the date line. Fires once per `run`, before the first model step.
    case systemPrompt(rendered: String)
    /// Tokens billed for one model step. Fires once per step — accumulate to get the turn total.
    case usage(TokenUsage, model: String)
    /// The output failed the caller-supplied validator. `willRetry` says whether a corrective
    /// prompt follows, so an observer can tell "about to be replaced" from "this is final".
    /// Only a host with a validator emits this; the loop itself never does.
    case validationFailed(issues: [String], willRetry: Bool)
}

/// Receives telemetry. Injected when constructing a loop or starting a host turn.
public typealias AgentTelemetrySink = @Sendable (AgentTelemetry) async -> Void
