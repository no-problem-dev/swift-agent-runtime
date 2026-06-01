import A2ACore
import A2AClientCore
import Foundation

/// ワーカー応答の受け取り方（公式 a2a-python `ClientConfig` の streaming/polling/blocking に対応）。
public enum DeliveryMode: String, Sendable, CaseIterable, Identifiable {
    /// SSE ストリーミング（`message/stream`）。途中の status/artifact を逐次受信。
    case streaming
    /// ブロッキング（`message/send`、`return_immediately=false`）。終端まで待って 1 回返る。
    case blocking
    /// 非ブロッキング（`return_immediately=true`）。即返し、`getTask` でポーリング。
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
    /// 配信モードに応じて `StreamResponse` を統一的に流す（消費側のコードはモード非依存）。
    /// 公式 `base_client.send_message`（streaming/polling 切替）と同じ考え方。
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
