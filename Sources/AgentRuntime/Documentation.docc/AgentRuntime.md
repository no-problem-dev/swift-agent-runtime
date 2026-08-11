# ``AgentRuntime``

Several agents working together: a host that delegates, workers that answer, and the plumbing
between them.

## Overview

`AgentLoopKit` runs one agent's turn. This module is what you import when one agent is not enough
— when a request should be split across specialists, run several of them at once, or be driven by
an app across a protocol boundary. It re-exports `AgentLoopKit`, `A2ACore`, `LLMClient` and
`LLMTool`, so a single import is usually all you need.

There are two kinds of host, and picking the wrong one is the most common mistake:

- ``HostAgent`` **delegates and composes.** It calls workers as tools, reads what they said, and
  writes its own answer. Worker output is flattened to text on the way in.
- ``RouterHostAgent`` **forwards and gets out of the way.** It picks one worker and passes its
  reply through untouched. Use it when the reply is structured and must survive intact — the
  composing host would destroy it.

### Registering workers

``AgentConnectionRegistry`` holds one connection per worker. Register by executor where you can:
that overload also wires up push notifications, which the client and handler overloads leave
inert.

```swift
import AgentRuntime

let registry = AgentConnectionRegistry()

await registry.register(
    card: AgentCard(name: "researcher", description: "Searches the web and summarises findings."),
    executor: LLMAgentExecutor(
        client: myClient,
        model: myModel,
        tools: ToolSet { WebSearchTool() }
    )
)
```

The name and description are not documentation — they are pasted verbatim into the host's prompt
and are the only thing the model has to route on. Write them for a reader.

### Delegating and composing

```swift
let host = HostAgent(client: myClient, model: myModel, registry: registry)

let answer = try await host.run("What are the latest trends in Swift concurrency?")

// The same instance keeps the conversation, tool calls and results included, so this
// follow-up can be answered from context without delegating again.
let followUp = try await host.run("Which of those affect iOS 17?")
```

The roster is re-read every turn, so a worker registered later becomes available without
rebuilding the host. Registering none is a supported configuration, not a broken one: the
delegation tools and the delegating wording are both dropped, and the host behaves as a plain
assistant. Leaving the delegation vocabulary in place with an empty fleet makes small on-device
models reach for tools that do not exist.

Cancelling the task around `run` cancels the turn and, through the structured tree, the workers it
is waiting on. ``HostAgent/cancel()`` does the same from outside and additionally cancels
background tasks that would otherwise outlive the turn.

### Running workers in parallel

``AgentConnectionRegistry/delegateAsync(to:text:delivery:)`` starts a worker and returns as soon as
it has accepted the task. Each call opens a fresh task, so concurrent delegations to the same
worker do not collide the way blocking ones do — a blocking delegation reuses the connection's
stored task in order to resume conversations.

```swift
let handle = try await registry.delegateAsync(to: "researcher", text: "Summarise the RFC")
let taskId = handle.taskId

// ... later, once the turn has already answered the user
let status = try await registry.checkTask(taskId!)
```

Nothing on the returned handle reflects the eventual result; its state is a snapshot from the
moment the worker accepted the work. Completion is delivered through the observer instead.

``BackgroundDelivery`` controls how that completion is noticed, and the three mechanisms are
layers rather than alternatives: subscribing gives live progress, push catches the case where the
stream was never established, and polling is the net under a worker that hangs. Only completion is
deduplicated — with several enabled, the same *progress* can be observed twice.

Tracked tasks are kept after they finish so results stay fetchable, and are never evicted, so a
long-lived registry accumulates one entry per background delegation.

### Watching delegations live

```swift
let registry = AgentConnectionRegistry(
    observer: { event in
        switch event {
        case .started(let id, let agent, let label):   openLane(id, agent, label)
        case .progress(let id, _, let response):       update(id, response)
        case .finished(let id, _, let text, let state): close(id, text, state)
        case .failed(let id, _, let error):            fail(id, error)
        }
    },
    usageObserver: { _, agent, usage in await meter.add(usage, for: agent) }
)
```

``DelegationEvent/finished(id:agent:text:state:)`` fires once per delegation whichever mechanism
saw the end first. Cost is kept on the separate usage observer so accounting never has to be
filtered out of the progress stream.

### Writing a worker

``LLMAgentExecutor`` wraps a single agent as an A2A worker and drives the task lifecycle: working
while the model runs, a status update naming each tool it calls, an artifact carrying the final
text, then completion. A turn that throws is reported as a failed task rather than propagated.

```swift
let executor = LLMAgentExecutor(
    client: myClient,
    model: myModel,
    tools: ToolSet { FileReadTool() },
    systemPrompt: SystemPrompt(stringLiteral: "You analyse files."),
    historyStore: InMemoryAgentHistoryStore()
)
```

Pass a history store unless you have a reason not to. Without one, a follow-up on the same task
rebuilds the conversation from the task history as flat text, which turns past tool calls into
assistant prose — and a model shown that pattern imitates it, answering where it should have
called a tool.

``HostAgentExecutor`` does the same for a whole orchestrator, which is how hosts nest.

### Forwarding structured replies

```swift
let router = RouterHostAgent(
    client: myClient,
    model: myModel,
    registry: registry,
    hooks: .init(
        preRoute: { parts in targetEncodedIn(parts) },   // nil falls back to the model
        prepareOutbound: { metadata, target in annotate(metadata, target) },
        observeWorkerParts: { parts, agent in record(parts, from: agent) }
    )
)

for try await event in await router.send(parts) {
    if case .worker(let response) = event { forward(response) }
}
```

Routing costs one model call per message unless `preRoute` decides without it — which is also why
`usage` is `nil` on a deterministic routing event.

### Driving a host from an app

``HostACPAgent`` exposes an orchestrator over ACP: the app is the client, this is the agent, and
delegation to workers stays A2A inside. One orchestrator is kept per session, and the conversation
is written under the session's working directory after every turn, which is what makes reloading a
session resume it.

Two behaviours to design around. A question and a finished answer project onto the same kind of
update, so the stop reason is the only signal that a turn is waiting on the user — this module
adds a non-standard `input_required` reason for exactly that. And session ids are derived from the
working directory's last path component, so two directories with the same name collide.

## Topics

### Hosts

- ``HostAgent``
- ``RouterHostAgent``
- ``HostAgentExecutor``

### Workers

- ``LLMAgentExecutor``
- ``AgentHistoryStore``
- ``InMemoryAgentHistoryStore``

### Connecting to workers

- ``AgentConnectionRegistry``
- ``AgentDescriptor``
- ``DeliveryMode``
- ``AgentSendOutcome``
- ``DelegationResult``

### Background delegation

- ``BackgroundDelivery``
- ``AgentTaskHandle``
- ``AgentTaskStatus``

### Observing delegations

- ``DelegationEvent``
- ``DelegationObserver``
- ``DelegationUsageObserver``

### Exposing a host over ACP

- ``HostACPAgent``
- ``HostACPAgentError``

### Errors

- ``AgentRuntimeError``
