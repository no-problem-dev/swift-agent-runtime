# swift-agent-runtime

English | [日本語](./README.ja.md)

A Swift package providing an LLM agent loop and A2A/ACP orchestration layer.

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017+%20%7C%20macOS%2014+-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

## Overview

`swift-agent-runtime` separates two concerns into distinct library targets:

- **`AgentLoopKit`** — A general-purpose agent loop with no A2A dependency. Depends on `swift-llm-client` and `swift-acp` (ACPCore) and handles LLM invocation, parallel tool execution, `input-required` interruption, and ACP `session/update` projection.
- **`AgentRuntime`** — An orchestration layer built on A2A. Provides `HostAgent` (delegation-loop style), `RouterHostAgent` (pass-through style), `LLMAgentExecutor` (worker), and `HostACPAgent` (ACP exposure).

## Architecture

```
App / CLI
   ↕ ACP (vertical boundary)
HostACPAgent
   ↕
HostAgent / RouterHostAgent
   ↕ A2A (horizontal boundary)
AgentConnectionRegistry  →  Workers (LLMAgentExecutor)
                                  ↕
                            AgentLoop (AgentLoopKit)
                                  ↕
                         LLMClient (swift-llm-client)
```

| Product | Role | Key dependencies |
|---|---|---|
| `AgentLoopKit` | LLM execution loop + ACP projection | `swift-llm-client`, `swift-acp` |
| `AgentRuntime` | A2A orchestration + ACP exposure | `AgentLoopKit`, `swift-a2a`, `swift-acp` |

### Key types in AgentLoopKit

| Type | Role |
|---|---|
| `AgentLoop<Client>` | Tool execution loop (`run` / `events` / `updates`) |
| `AgentLoop.Event` | Semantic events (`thinking` / `toolCall` / `toolResult` / `inputRequired` / `completed`) |
| `AgentEvent` | Client-independent mirror of `AgentLoop.Event` (type-erased) |
| `AgentTelemetry` / `AgentTelemetrySink` | Side-band observations (`usage` / `systemPrompt` / `validationFailed`) |
| `UsageAccumulator` | Cumulative token-usage accumulator within a turn |
| `InteractiveRuntimeTool` | Marker protocol: interrupts the loop and emits `inputRequired` when called |
| `RequestUserInputTool` | Standard interactive tool (`request_user_input`) |

### Key types in AgentRuntime

| Type | Role |
|---|---|
| `HostAgent<Client>` | Orchestrator that delegates to A2A workers. Maintains conversation history and exposes `run` / `stream` |
| `RouterHostAgent<Client>` | Routing-only orchestrator that forwards to exactly one worker and passes through the response |
| `HostACPAgent<Client>` | Exposes `HostAgent` as an ACP agent. Handles session management and conversation persistence |
| `LLMAgentExecutor<Client>` | Worker that runs `AgentLoop` as an A2A `AgentExecutor` |
| `AgentConnectionRegistry` | Registers workers, dispatches delegations, and manages background tasks |
| `AgentHistoryStore` / `InMemoryAgentHistoryStore` | LLM conversation history store for workers (swappable) |
| `DeliveryMode` | Controls how worker responses are received (`streaming` / `blocking` / `polling`) |
| `BackgroundDelivery` | Completion delivery strategy for non-blocking delegation (`subscribe` / `push` / `pollInterval`) |

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-agent-runtime.git", .upToNextMajor(from: "0.10.0"))
]
```

```swift
// Loop only (no A2A dependency)
.target(name: "YourTarget", dependencies: [
    .product(name: "AgentLoopKit", package: "swift-agent-runtime"),
])

// A2A orchestration included
.target(name: "YourTarget", dependencies: [
    .product(name: "AgentRuntime", package: "swift-agent-runtime"),
])
```

## Quick Start

### AgentLoopKit — Standalone agent loop

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
    case .thinking(let text):
        print("thinking: \(text)")
    case .toolCall(_, let name, _):
        print("calling tool: \(name)")
    case .toolResult(_, _, let output, let isError):
        print("tool result (error=\(isError)): \(output)")
    case .inputRequired(let question):
        print("needs user input: \(question)")
    case .completed(let text):
        print("completed: \(text)")
    }
}
```

Receiving telemetry (cost tracking):

```swift
let accumulator = UsageAccumulator()

let loop = AgentLoop(
    client: myLLMClient,
    model: myModel,
    telemetry: { telemetry in
        if case let .usage(usage, model) = telemetry {
            await accumulator.add(usage)
            print("[\(model)] input=\(usage.inputTokens) output=\(usage.outputTokens)")
        }
    }
)
```

### AgentRuntime — HostAgent delegating to in-process workers

```swift
import AgentRuntime

// 1. Register a worker
let registry = AgentConnectionRegistry()

let workerExecutor = LLMAgentExecutor(
    client: myLLMClient,
    model: myModel,
    systemPrompt: SystemPrompt(stringLiteral: "You are a research specialist."),
    maxSteps: 8
)
let workerCard = AgentCard(
    name: "researcher",
    description: "Searches and summarizes information on any topic."
)
await registry.register(card: workerCard, executor: workerExecutor)

// 2. Create a HostAgent and send a request
let host = HostAgent(
    client: myLLMClient,
    model: myModel,
    registry: registry
)

let result = try await host.run("Research the latest trends in quantum computing.")
print(result)

// Streaming
for try await event in await host.stream("What are Swift Concurrency best practices?") {
    if case .completed(let text) = event { print(text) }
}
```

### Background delegation (non-blocking)

```swift
// delegate_async: returns immediately; worker continues in the background
let handle = try await registry.delegateAsync(
    to: "researcher",
    text: "Analyze the latest data from space telescopes.",
    delivery: .all   // subscribe + push + poll simultaneously
)
print("taskId=\(handle.taskId?.rawValue ?? "nil")")

// Check later
let status = try await registry.checkTask(handle.taskId!)
print("state=\(status.state), text=\(status.text)")

// List running tasks
let running = await registry.listRunningTasks()
```

### RouterHostAgent — Pass-through router

```swift
import AgentRuntime

let router = RouterHostAgent(
    client: myLLMClient,
    model: myModel,
    registry: registry,
    hooks: RouterHostAgent.Hooks(
        // Deterministic routing without LLM (e.g. route by surfaceId from userAction)
        preRoute: { parts in
            guard let text = parts.first?.text else { return nil }
            return text.contains("image") ? "vision-agent" : nil
        }
    )
)

for try await event in await router.send([Part.text("Analyze this image.")]) {
    switch event {
    case .routed(let agent, let deterministic, _):
        print("routed to \(agent) (deterministic=\(deterministic))")
    case .worker(let streamResponse):
        // Pass-through from the worker
        break
    }
}
```

### HostACPAgent — Session management at the ACP boundary

```swift
import AgentRuntime

let acpAgent = HostACPAgent(
    client: acpClient,
    telemetry: { telemetry in
        // cost tracking, etc.
    },
    makeHost: {
        HostAgent(client: llmClient, model: model, registry: registry)
    }
)
// acpAgent implements ACPAgent; pass it to the ACP framework to get
// session management, conversation persistence (cwd/conversation.json),
// and multimodal input handling automatically.
```

## Supported Platforms / Requirements

| Platform | Minimum version |
|---|---|
| macOS | 14.0+ |
| iOS | 17.0+ |

- Swift 6.2+
- Dependencies: [swift-a2a](https://github.com/no-problem-dev/swift-a2a) 0.6.2+, [swift-llm-client](https://github.com/no-problem-dev/swift-llm-client) 3.7.0+, [swift-structured-data](https://github.com/no-problem-dev/swift-structured-data) 1.3.0+, [swift-acp](https://github.com/no-problem-dev/swift-acp) 0.1.0+

## License

MIT
