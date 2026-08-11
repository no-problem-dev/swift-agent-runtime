# ``AgentLoopKit``

The turn loop on its own: call the model, run the tools it asks for, feed the results back, repeat.

## Overview

Give ``AgentLoop`` a client, a model and a tool set, and it runs a whole turn. Each round it asks
the model for a step, executes whatever tools the step requested, appends the results and asks
again — until the model answers without calling a tool, a turn-ending tool succeeds, or the step
budget runs out. It returns the full transcript, tool calls and results included, which is also
what you pass back in to continue the conversation.

This module knows nothing about agent-to-agent delegation. If you need a host that hands work to
workers, or a session boundary over ACP, use `AgentRuntime`, which builds on this loop.

Three things are worth knowing before you start:

- **Text always arrives as deltas.** A provider that cannot stream still emits its whole step as a
  single delta, so concatenating deltas never loses text. The text on `completed` repeats the same
  content for history — render one or the other, not both.
- **A failing tool does not throw.** The error is stringified into a failed tool result and fed
  back so the model can recover. Only cancellation and client failures propagate.
- **`run` and `events` differ on cancellation.** `run(messages:onEvent:)` executes on your task, so
  cancelling it cancels the model step and every running tool. `events(messages:)` uses an
  unstructured task and does *not* inherit your cancellation — ending the stream is what stops it.

### Running a turn

```swift
import AgentLoopKit

let loop = AgentLoop(
    client: myClient,
    model: myModel,
    tools: ToolSet { SearchTool() },
    systemPrompt: SystemPrompt(stringLiteral: "You are a helpful assistant."),
    maxSteps: 12
)

var answer = ""
let transcript = try await loop.run(messages: [.user("What changed in Swift recently?")]) { event in
    switch event {
    case .textDelta(let chunk):
        answer += chunk
    case .toolCall(_, let name, _):
        print("calling \(name)")
    case .toolResult(_, let name, let output, let isError):
        print(isError ? "\(name) failed: \(output)" : "\(name) ok")
    case .completed(let text):
        answer = text
    case .thinkingDelta, .inputRequired, .toolApprovalRequired:
        break
    }
}
```

Pass `transcript` straight back as `messages` on the next turn and the model keeps everything it
already did as context. Note that `completed` also fires with empty text when `maxSteps` is
exhausted, so receiving it is not by itself proof the model finished the job.

### Consuming events as a stream

``AgentLoop/events(messages:pendingToolDecisions:)`` delivers the same events without a callback,
which suits driving a view directly.

```swift
for try await event in loop.events(messages: history) {
    if case .completed(let text) = event { render(text) }
}
```

The loop runs in its own task here, so it keeps going even if the surrounding task is cancelled.
Break out of the loop, or let the stream deallocate, to stop it.

### Pausing to ask the user

A tool conforming to ``InteractiveRuntimeTool`` is never executed. When the model requests it, the
loop stops and reports the question instead, so the tool body is a place to phrase a question, not
to perform work.

```swift
let loop = AgentLoop(
    client: myClient,
    model: myModel,
    tools: ToolSet { RequestUserInputTool() }
)

let suspended = try await loop.run(messages: [.user("Delete the old exports")]) { event in
    if case .inputRequired(let question) = event { show(question) }
}

// Resume by continuing the same transcript with the user's reply.
let finished = try await loop.run(messages: suspended + [.user("Yes, delete them")]) { _ in }
```

### Requiring approval before a tool runs

``ApprovalRequiringTool`` suspends the turn *before* anything executes — including the tools in the
same batch that need no approval, so a partly applied batch is not a state you can reach. Collect
the verdicts, then call `run` again with the same transcript.

```swift
var pending: [String: ToolApprovalDecision] = [:]

let suspended = try await loop.run(messages: [.user("Follow these three shops")]) { event in
    if case .toolApprovalRequired(let id, _, _, let request) = event {
        pending[id] = ask(request.summary, request.details) ? .approved : .denied
    }
}

try await loop.run(messages: suspended, pendingToolDecisions: pending) { event in
    // Approved calls execute without re-emitting toolCall; denied ones never run.
}
```

A denied call is answered with a synthetic *success* result telling the model not to retry.
Reporting it as an error would read to the model as something worth attempting again.

### Cost and debugging on a side channel

``AgentTelemetry`` carries what the events deliberately leave out: tokens per step and the fully
assembled system prompt. Keeping them apart is what lets UI state be driven from the event stream
alone.

```swift
let accumulator = UsageAccumulator()

let loop = AgentLoop(
    client: myClient,
    model: myModel,
    tools: myTools,
    telemetry: { event in
        switch event {
        case .usage(let usage, _):        await accumulator.add(usage)
        case .systemPrompt(let rendered): logPrompt(rendered)
        case .validationFailed:           break
        }
    }
)

_ = try await loop.run(messages: history) { _ in }
let total = await accumulator.total
```

The sink fires from whichever task ran the step, which is why ``UsageAccumulator`` is an actor;
summing into a plain variable would race.

### Projecting onto ACP

``AgentLoop/updates(messages:)`` converts the same turn into ACP `session/update` values, ready to
forward to a client.

```swift
for try await update in loop.updates(messages: history) {
    try await acpClient.sessionUpdate(
        SessionNotification(sessionId: sessionId, update: update)
    )
}
```

Two gaps are worth knowing. Token usage is not projected — ACP's `usage_update` is produced from
the telemetry sink instead. And ACP has no approval vocabulary, so an approval request appears as
an ordinary message: a client driven only by these updates has no way to send a verdict back.

## Topics

### The loop

- ``AgentLoop``
- ``AgentEvent``

### Suspending a turn

- ``InteractiveRuntimeTool``
- ``RequestUserInputTool``
- ``ApprovalRequiringTool``
- ``ToolApprovalRequest``
- ``ToolApprovalDecision``

### Cost and diagnostics

- ``AgentTelemetry``
- ``AgentTelemetrySink``
- ``UsageAccumulator``
