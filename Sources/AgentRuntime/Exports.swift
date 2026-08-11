// Importing AgentRuntime is enough to write a worker.
//
// A2AServer and A2AInProcess are deliberately not re-exported: code that hosts a server or wires
// things up in-process must depend on swift-a2a itself. Leaning on incidental visibility grows
// coupling that never shows up in the dependency graph.
@_exported import AgentLoopKit
import A2ACore
import LLMClient
import LLMTool
