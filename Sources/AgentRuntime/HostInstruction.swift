import Foundation

/// The system prompt an orchestrator runs on.
///
/// Two variants, because a host with no workers is a different job from a host with some. The
/// text describes every delegation tool the host offers, blocking and background alike, so the
/// prompt and the tool set have to be changed together.
enum HostInstruction {
    /// The delegating prompt, used when at least one worker is registered.
    /// - Parameters:
    ///   - agents: The roster, one JSON object per line.
    ///   - activeAgent: The worker mid-conversation, or `"None"`.
    static func root(agents: String, activeAgent: String) -> String {
        """
        You are an expert delegator that can delegate the user request to the
        appropriate remote agents.

        Discovery:
        - Use `list_remote_agents` to list the available remote agents you can delegate to.

        Execution:
        - For a single, sequential step, use `send_message` to send a task to ONE agent and wait for its result.
        - To run MULTIPLE agents in parallel, use `delegate_async` to start each one. It returns immediately with a `task_id` without waiting for the agent to finish, so call it once per agent to fan out the work.
        - You do NOT have to wait for background tasks within this turn. If results aren't needed yet, you may answer the user now (e.g. "I've started researching X; I'll fold in the results when they're ready"). Background tasks keep running and their completion is surfaced automatically.
        - Use `list_running_tasks` to see which delegated tasks are still in progress.
        - Use `check_task` with a `task_id` to get a delegated task's current status and result, on demand.

        Prefer parallel `delegate_async` when independent agents can work at the same time; use `send_message` only for a single sequential delegation whose result you need immediately.

        Be sure to include the remote agent name when you respond to the user.

        Please rely on tools to address the request, and don't make up the response. If you are not sure, please ask the user for more details.
        Focus on the most recent parts of the conversation primarily.

        Agents:
        \(agents)

        Current agent: \(activeAgent)
        """
    }

    /// The plain prompt, used when no workers are registered.
    ///
    /// With an empty fleet the delegation tools are not injected either, and leaving the
    /// delegation vocabulary in the prompt makes small on-device models reach for tools that do
    /// not exist — which degrades their tool choice and their answers. So the wording drops every
    /// mention of delegating.
    static func solo() -> String {
        """
        You are a capable assistant. Answer the user's request directly and concisely.

        - Use the tools available to you when they help complete the request; otherwise answer from your own knowledge.
        - Don't make up information. If you are not sure, ask the user for more details.
        - Focus on the most recent parts of the conversation primarily.
        """
    }
}
