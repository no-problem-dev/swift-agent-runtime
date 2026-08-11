# swift-agent-runtime

English | [日本語](./README.ja.md)

Build an LLM agent that keeps calling your tools until a task is done, and have several such agents hand work to one another.

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017+%20%7C%20macOS%2014+%20%7C%20Linux-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

## Overview

You write the tools and the prompt. This package runs the turn: call the model, execute the tools it
asks for, feed the results back, and stop when the model is finished or the step ceiling is reached.

- **Watch the turn as it happens** — thinking, tool calls, tool results and completion arrive as
  events you can render, rather than as one string at the end
- **Tools run in parallel by default** — turn it off and calls are made one at a time, in the order
  the model asked for them
- **A tool can stop and ask the user** — the loop suspends, surfaces the question, and resumes with
  the answer instead of forcing you to invent one
- **Token usage arrives on a side channel** — cost accounting does not have to be threaded through
  your tool code
- **Delegate to other agents** — hand a sub-task to a worker and wait for it, or take a handle and
  collect the result later while the conversation continues
- **Take only what you need** — `AgentLoopKit` is the loop on its own; `AgentRuntime` adds
  agent-to-agent delegation and session handling on top of it

## Quick Start

```swift
import AgentLoopKit

let loop = AgentLoop(
    client: myLLMClient,
    model: myModel,
    tools: ToolSet {
        MySearchTool()
        RequestUserInputTool()
    },
    systemPrompt: SystemPrompt(stringLiteral: "You are a helpful assistant."),
    maxSteps: 12
)

for try await event in loop.events(messages: [.user("What is the weather in Tokyo today?")]) {
    switch event {
    case .thinking(let text):            print("thinking: \(text)")
    case .toolCall(_, let name, _):      print("calling tool: \(name)")
    case .toolResult(_, _, let out, let isError): print("result (error=\(isError)): \(out)")
    case .inputRequired(let question):   print("needs user input: \(question)")
    case .completed(let text):           print("completed: \(text)")
    }
}
```

Hand a sub-task to a worker agent and wait for its answer:

```swift
import AgentRuntime

let registry = AgentConnectionRegistry()
await registry.register(
    card: AgentCard(name: "researcher", description: "Searches and summarizes any topic."),
    executor: LLMAgentExecutor(client: myLLMClient, model: myModel, maxSteps: 8)
)

let host = HostAgent(client: myLLMClient, model: myModel, registry: registry)
print(try await host.run("Research the latest trends in quantum computing."))
```

## Documentation

[**AgentLoopKit**](https://no-problem-dev.github.io/swift-agent-runtime/documentation/agentloopkit/) —
the loop, its events, tools and telemetry.

[**AgentRuntime**](https://no-problem-dev.github.io/swift-agent-runtime/documentation/agentruntime/) —
delegation between agents, background tasks, and exposing a host over ACP.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-agent-runtime.git", .upToNextMinor(from: "0.20.0"))
]
```

Add the product you need. `AgentLoopKit` carries no agent-to-agent dependency:

```swift
.product(name: "AgentLoopKit", package: "swift-agent-runtime"),   // loop only
.product(name: "AgentRuntime", package: "swift-agent-runtime"),   // loop + delegation
```

## Requirements

- iOS 17.0+ / macOS 14.0+ / Linux
- Swift 6.2+

## License

MIT — see [LICENSE](LICENSE).
