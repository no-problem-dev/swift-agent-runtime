import Foundation

/// ホスト（オーケストレータ）の root instruction。
///
/// Google a2a-samples `samples/python/hosts/multiagent/host_agent.py` の `root_instruction` を
/// **逐語移植**したもの。可変部は登録エージェント一覧 `agents`（1 行 1 JSON）と現在エージェント
/// `activeAgent` のみ。独自の workflow 文を足して実装誤差で精度を落とさないため、本文は触らない。
public enum HostInstruction {
    /// `host_agent.py` の `root_instruction` 相当の文字列を返す。
    /// - Parameters:
    ///   - agents: `register_agent_card` の `self.agents`（`'\n'.join(json.dumps({name,description}))`）相当。
    ///   - activeAgent: `check_state` の `active_agent`（継続中のみ名前、なければ `"None"`）。
    public static func root(agents: String, activeAgent: String) -> String {
        """
        You are an expert delegator that can delegate the user request to the
        appropriate remote agents.

        Discovery:
        - You can use `list_remote_agents` to list the available remote agents you
        can use to delegate the task.

        Execution:
        - For actionable requests, you can use `send_message` to interact with remote agents to take action.

        Be sure to include the remote agent name when you respond to the user.

        Please rely on tools to address the request, and don't make up the response. If you are not sure, please ask the user for more details.
        Focus on the most recent parts of the conversation primarily.

        Agents:
        \(agents)

        Current agent: \(activeAgent)
        """
    }
}
