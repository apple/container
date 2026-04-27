//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if os(macOS)
import ContainerizationError
import Foundation

public final class XPCClient: Sendable {
    /// The maximum amount of time to wait for a request to a recently
    /// registered XPC service. Once a service has launched, XPC
    /// requests only have milliseconds of overhead, but in some instances,
    /// macOS can take 5 seconds (or considerably longer) to launch a
    /// service after it has been registered.
    public static let xpcRegistrationTimeout: Duration = .seconds(60)

    private nonisolated(unsafe) let connection: xpc_connection_t
    private let q: DispatchQueue?
    private let service: String

    public init(service: String, queue: DispatchQueue? = nil) {
        let connection = xpc_connection_create_mach_service(service, queue, 0)
        self.connection = connection
        self.q = queue
        self.service = service

        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_set_target_queue(connection, self.q)
        xpc_connection_activate(connection)
    }

    public init(connection: xpc_connection_t, label: String, queue: DispatchQueue? = nil) {
        self.connection = connection
        self.q = queue
        self.service = label

        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_set_target_queue(connection, self.q)
        xpc_connection_activate(connection)
    }

    deinit {
        self.close()
    }
}

extension XPCClient {
    /// Close the underlying XPC connection.
    public func close() {
        xpc_connection_cancel(connection)
    }

    /// Returns the pid of process to which we have a connection.
    /// Note: `xpc_connection_get_pid` returns 0 if no activity
    /// has taken place on the connection prior to it being called.
    public func remotePid() -> pid_t {
        xpc_connection_get_pid(self.connection)
    }

    /// Send the provided message to the service and wait for the reply.
    ///
    /// Use this overload for **mutating or unknown-safety** requests. It has no
    /// response timeout: once the message has been dispatched, this function
    /// blocks until the XPC service replies or the underlying connection is
    /// invalidated.
    ///
    /// Cancellation is honored only **before dispatch**
    /// (`Task.checkCancellation()`). After the message is sent, `Task`
    /// cancellation does not resume the caller, because doing so would let the
    /// server commit a mutation after the caller had already given up — the
    /// classic late-reply race that creates duplicate or out-of-order state.
    ///
    /// For read-only or idempotent requests where dropping a late reply is
    /// acceptable, use ``send(_:timeoutForIdempotentRequest:)`` instead.
    ///
    /// See `docs/internal/codex-reviews.md` and
    /// `docs/internal/help-freeze-analysis.md` for the full design rationale.
    @discardableResult
    public func send(_ message: XPCMessage) async throws -> XPCMessage {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<XPCMessage, Error>) in
            xpc_connection_send_message_with_reply(self.connection, message.underlying, nil) { reply in
                do {
                    cont.resume(returning: try self.parseReply(reply))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Send the provided message to the service with an idempotency-safe
    /// timeout.
    ///
    /// The response is delivered by whichever of the following completes first:
    ///   1. The XPC reply callback fires.
    ///   2. `responseTimeout` elapses.
    ///   3. The current `Task` is cancelled.
    ///
    /// **Use this overload only for read-only or idempotent requests.** When
    /// timeout or cancellation wins the race, the underlying XPC reply callback
    /// may still fire later and the server may still complete the operation.
    /// Late completions are dropped silently so the connection remains valid
    /// for subsequent sends — important for callers that hold a long-lived
    /// `XPCClient` (`ContainerClient`, `NetworkClient`). For mutating requests
    /// this would create duplicate or out-of-order server-side state; use
    /// ``send(_:)`` instead.
    ///
    /// A previous implementation used a `withThrowingTaskGroup`, but
    /// structured-concurrency cleanup awaited the XPC child task, which could
    /// not actually be cancelled because
    /// `xpc_connection_send_message_with_reply` only resumes when its callback
    /// fires. That made the timeout ineffective whenever the remote service was
    /// wedged. See docs/internal/help-freeze-analysis.md.
    @discardableResult
    public func send(
        _ message: XPCMessage,
        timeoutForIdempotentRequest responseTimeout: Duration
    ) async throws -> XPCMessage {
        let state = ResumptionState<XPCMessage>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<XPCMessage, Error>) in
                state.set(cont)

                xpc_connection_send_message_with_reply(self.connection, message.underlying, nil) { reply in
                    do {
                        let parsed = try self.parseReply(reply)
                        state.tryResume(returning: parsed)
                    } catch {
                        state.tryResume(throwing: error)
                    }
                }

                let service = self.service
                let route = message.string(key: XPCMessage.routeKey) ?? "nil"
                Task { [state] in
                    try? await Task.sleep(for: responseTimeout)
                    state.tryResume(
                        throwing: ContainerizationError(
                            .timeout,
                            message: "XPC timeout for request to \(service)/\(route)"
                        )
                    )
                }

                // Close the race window: if cancellation arrived before `set(cont)`
                // ran, the cancellation handler resumed against an empty state. Resume
                // here so the continuation cannot be lost.
                if Task.isCancelled {
                    state.tryResume(throwing: CancellationError())
                }
            }
        } onCancel: {
            state.tryResume(throwing: CancellationError())
        }
    }

    /// Compile-time guard against the previous footgun spelling.
    ///
    /// The previous API allowed any caller to pass `responseTimeout:` regardless
    /// of whether the request mutated server-side state. When the timeout fired
    /// against a mutating request, the server could still commit the operation
    /// while the caller had already given up — the late-reply race documented in
    /// `docs/internal/codex-reviews.md`.
    ///
    /// This unavailable shim keeps the old call shape compiling-as-error so
    /// callers are forced to choose either ``send(_:)`` for mutating requests
    /// or ``send(_:timeoutForIdempotentRequest:)`` for idempotent ones.
    @available(*, unavailable, message: "responseTimeout may drop late replies. Use send(_:) for mutating requests, or send(_:timeoutForIdempotentRequest:) only for idempotent/read-only requests.")
    @discardableResult
    public func send(_ message: XPCMessage, responseTimeout: Duration?) async throws -> XPCMessage {
        fatalError("unavailable")
    }

    private func parseReply(_ reply: xpc_object_t) throws -> XPCMessage {
        switch xpc_get_type(reply) {
        case XPC_TYPE_ERROR:
            var code = ContainerizationError.Code.invalidState
            if reply.connectionError {
                code = .interrupted
            }
            throw ContainerizationError(
                code,
                message: "XPC connection error: \(reply.errorDescription ?? "unknown")"
            )
        case XPC_TYPE_DICTIONARY:
            let message = XPCMessage(object: reply)
            // check errors from our protocol
            try message.error()
            return message
        default:
            fatalError("unhandled xpc object type: \(xpc_get_type(reply))")
        }
    }
}

/// Single-resume gate around a `CheckedContinuation`.
///
/// `XPCClient.send` races multiple completion sources (XPC reply callback, timeout
/// sleep, parent-task cancellation) against a single continuation. Whichever wins
/// resumes via `tryResume`; subsequent resumes are dropped silently.
private final class ResumptionState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func tryResume(returning value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    func tryResume(throwing error: Error) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}

#endif
