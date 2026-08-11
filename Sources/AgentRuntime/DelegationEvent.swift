import A2ACore
import A2AClientCore
import LLMClient

/// The life of one delegation, reported while it runs so a UI can show it live.
///
/// This is independent of what the delegation tool returns to the model: the tool blocks until
/// the worker finishes, whereas these arrive throughout. `id` identifies a single delegation, so
/// two concurrent delegations to the same worker stay in separate lanes. Token usage is not here
/// — it goes to the usage observer instead.
public enum DelegationEvent: Sendable {
    /// A worker was handed a task. `label` is the opening of the message, truncated for display.
    case started(id: String, agent: String, label: String)
    /// A raw event from the worker. For a background delegation the same underlying progress can
    /// arrive more than once, since subscribe, poll and push all forward what they see.
    case progress(id: String, agent: String, response: StreamResponse)
    /// The worker reached a terminal state. Fires exactly once per delegation, whichever delivery
    /// mechanism observed the end first. For a background task that never terminates, this can
    /// still fire with a non-terminal state once the wait budget runs out.
    case finished(id: String, agent: String, text: String, state: TaskState?)
    /// The delegation threw before reaching a terminal state. The error is already stringified.
    case failed(id: String, agent: String, error: String)
}

/// Receives delegation lifecycle events. Injected when creating the registry.
public typealias DelegationObserver = @Sendable (DelegationEvent) async -> Void

/// Receives what a worker spent, read from the artifact it produced. Separate from the lifecycle
/// observer so cost accounting never has to be filtered out of the progress stream. Not
/// deduplicated: the same usage can be reported again if several delivery mechanisms see it.
public typealias DelegationUsageObserver = @Sendable (_ id: String, _ agent: String, _ usage: TokenUsage) async -> Void
