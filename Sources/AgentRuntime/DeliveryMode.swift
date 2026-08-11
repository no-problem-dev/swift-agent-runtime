import A2ACore
import A2AClientCore
import Foundation

/// How a worker's reply is collected off the wire.
///
/// This picks the transport, not whether the caller waits: every mode is consumed to the end
/// before a delegation returns. It changes what intermediate progress is visible, and how much
/// the worker's server is asked to support.
public enum DeliveryMode: String, Sendable, CaseIterable, Identifiable {
    /// Server-sent events. Status and artifact updates arrive as they happen — the only mode that
    /// shows real progress. Requires a worker that supports streaming.
    case streaming
    /// One request, one reply, after the worker has finished. No intermediate progress.
    case blocking
    /// The worker returns a task immediately and the state is re-read on an interval until it is
    /// terminal. Progress arrives at the polling granularity; use it when streaming is unavailable.
    case polling

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .streaming: "Streaming (SSE)"
        case .blocking: "Blocking"
        case .polling: "Polling"
        }
    }
}

extension A2AClient {
    /// Streams a worker's reply, presenting all three delivery modes as the same event sequence.
    ///
    /// The work runs in an unstructured task, so it does not inherit the caller's cancellation —
    /// terminating the stream is what stops it, including an in-progress polling loop.
    ///
    /// - Parameters:
    ///   - message: The message to send.
    ///   - mode: Which transport to use.
    ///   - pollInterval: Gap between task re-reads. Used only by `.polling`.
    public func events(
        _ message: Message,
        mode: DeliveryMode,
        pollInterval: Duration = .milliseconds(150)
    ) -> AsyncThrowingStream<StreamResponse, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch mode {
                    case .streaming:
                        for try await event in try await self.sendStreamingMessageEvents(message) {
                            continuation.yield(event)
                        }

                    case .blocking:
                        switch try await self.sendMessage(message) {
                        case .task(let t): continuation.yield(.task(t))
                        case .message(let m): continuation.yield(.message(m))
                        }

                    case .polling:
                        let response = try await self.sendMessage(
                            SendMessageRequest(message: message,
                                               configuration: SendMessageConfiguration(returnImmediately: true))
                        )
                        switch response {
                        case .message(let m):
                            continuation.yield(.message(m))
                        case .task(let started):
                            continuation.yield(.task(started))
                            var current = started
                            while !current.status.state.isTerminal, !current.status.state.isInterrupted {
                                try await Task.sleep(for: pollInterval)
                                current = try await self.getTask(started.id)
                                continuation.yield(.task(current))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func sendStreamingMessageEvents(_ message: Message) async throws -> AsyncThrowingStream<StreamResponse, Error> {
        try await streamMessage(message)
    }
}
