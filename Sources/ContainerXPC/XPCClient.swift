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

/// A reply, timeout, and task cancellation can arrive on different threads.
/// Keep the continuation until exactly one of them completes the request.
private final class PendingReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<XPCMessage, any Error>?
    private var result: Result<XPCMessage, any Error>?
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<XPCMessage, any Error>) -> Bool {
        let result = lock.withLock { () -> Result<XPCMessage, any Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let result {
            continuation.resume(with: result)
            return false
        }
        return true
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        let completed = lock.withLock { () -> Bool in
            if result != nil { return true }
            timeoutTask = task
            return false
        }
        if completed { task.cancel() }
    }

    func complete(_ result: Result<XPCMessage, any Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<XPCMessage, any Error>?, Task<Void, Never>?) in
            guard self.result == nil else { return (nil, nil) }
            self.result = result
            let pending = (continuation, timeoutTask)
            continuation = nil
            timeoutTask = nil
            return pending
        }
        pending.1?.cancel()
        pending.0?.resume(with: result)
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

    /// Install a handler that is called whenever the connection receives an XPC error event.
    ///
    /// This replaces the existing (no-op) event handler. Call this before the first
    /// `send()` to avoid a disconnect-before-handler race.
    ///
    /// ```swift
    /// let client = XPCClient(service: "com.example.myservice")
    /// client.setDisconnectHandler {
    ///     print("service disconnected, cleaning up")
    /// }
    /// let response = try await client.send(request)
    /// ```
    public func setDisconnectHandler(_ handler: @Sendable @escaping () -> Void) {
        xpc_connection_set_event_handler(connection) { object in
            if xpc_get_type(object) == XPC_TYPE_ERROR { handler() }
        }
    }

    /// Create a persistent session backed by this client connection.
    ///
    /// The session installs a disconnect handler at initialisation time, before
    /// any messages are sent, ensuring no server-exit event is missed.
    public func openSession() -> XPCClientSession {
        XPCClientSession(client: self)
    }

    /// Send the provided message to the service.
    @discardableResult
    public func send(_ message: XPCMessage, responseTimeout: Duration? = nil) async throws -> XPCMessage {
        // The reply handler only holds the pending request weakly. Keep this
        // client and its connection alive until the request has completed.
        defer { withExtendedLifetime(self) {} }
        let pending = PendingReply()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending.install(continuation) else { return }

                xpc_connection_send_message_with_reply(self.connection, message.underlying, nil) { [weak pending] reply in
                    pending?.complete(Result { try Self.parseReply(reply) })
                }

                if let responseTimeout {
                    let task = Task {
                        do {
                            try await Task.sleep(for: responseTimeout)
                        } catch {
                            return
                        }
                        let route = message.string(key: XPCMessage.routeKey) ?? "nil"
                        pending.complete(
                            .failure(
                                ContainerizationError(
                                    .internalError,
                                    message: "XPC timeout for request to \(self.service)/\(route)"
                                )))
                    }
                    pending.setTimeoutTask(task)
                }
            }
        } onCancel: {
            pending.complete(.failure(CancellationError()))
        }
    }

    private static func parseReply(_ reply: xpc_object_t) throws -> XPCMessage {
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

#endif
