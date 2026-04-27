//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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
import Testing

@testable import ContainerXPC

/// Tests for the mutating-vs-idempotent `XPCClient.send` contract introduced
/// in response to the Codex adversarial review of `fix/help-command-freeze`.
/// See `docs/internal/codex-reviews.md`.
struct XPCClientTests {

    // MARK: - timeoutForIdempotentRequest contract

    @Test
    func idempotentTimeoutReturnsWithinBound() async throws {
        let server = LocalXPCServer(handler: { _ in /* never reply */ })
        defer { server.shutdown() }
        let client = server.makeClient()
        let request = XPCMessage(route: "test.idempotent.timeout")

        let timeout: Duration = .milliseconds(300)
        let start = ContinuousClock.now
        let thrown = await Result { try await client.send(request, timeoutForIdempotentRequest: timeout) }
        let elapsed = ContinuousClock.now - start

        switch thrown {
        case .success:
            Issue.record("send should have thrown; instead returned a value")
        case .failure(let error):
            let cz = try #require(error as? ContainerizationError, "expected ContainerizationError, got \(type(of: error))")
            #expect(cz.code == .timeout, "expected .timeout, got .\(cz.code) — \(cz.message)")
        }
        #expect(elapsed >= timeout, "should not return before the timeout window (elapsed: \(elapsed))")
        #expect(elapsed < timeout * 5, "should return promptly after timeout (elapsed: \(elapsed))")
    }

    @Test
    func reusableClientSurvivesIdempotentTimeout() async throws {
        // First call never replies; second call replies immediately. The single
        // shared XPCClient must continue to work after the first call times out.
        let replyImmediately = Mutex(false)
        let server = LocalXPCServer(handler: { request in
            if replyImmediately.get() {
                request.reply()
            }
            // else: drop silently, simulating a hung server
        })
        defer { server.shutdown() }
        let client = server.makeClient()

        let firstResult = await Result {
            try await client.send(
                XPCMessage(route: "test.first"),
                timeoutForIdempotentRequest: .milliseconds(200)
            )
        }
        let cz = try #require((firstResult.error()) as? ContainerizationError)
        #expect(cz.code == .timeout, "first send should time out, got .\(cz.code) — \(cz.message)")

        replyImmediately.set(true)
        let response = try await client.send(
            XPCMessage(route: "test.second"),
            timeoutForIdempotentRequest: .seconds(5)
        )
        #expect(response.string(key: XPCMessage.routeKey) != nil, "reply should be a valid XPC dictionary")
    }

    @Test
    func lateReplyAfterIdempotentTimeoutIsIgnoredCleanly() async throws {
        // Server delays its reply past the client's timeout. Verify the client
        // surfaces the timeout AND that a subsequent send still works (i.e., the
        // late reply did not corrupt connection state or cause a crash).
        let server = LocalXPCServer(handler: { request in
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                request.reply()
            }
        })
        defer { server.shutdown() }
        let client = server.makeClient()

        let firstResult = await Result {
            try await client.send(
                XPCMessage(route: "test.late"),
                timeoutForIdempotentRequest: .milliseconds(150)
            )
        }
        let cz = try #require((firstResult.error()) as? ContainerizationError)
        #expect(cz.code == .timeout, "first send should time out, got .\(cz.code) — \(cz.message)")

        // Wait long enough that the late reply has fired and been silently dropped.
        try await Task.sleep(for: .milliseconds(500))

        // Connection must still be usable.
        let response = try await client.send(
            XPCMessage(route: "test.after-late"),
            timeoutForIdempotentRequest: .seconds(5)
        )
        #expect(response.string(key: XPCMessage.routeKey) != nil)
    }

    // MARK: - send(_:) mutating-safe contract

    @Test
    func plainSendCompletesWhenServerReplies() async throws {
        let server = LocalXPCServer(handler: { request in
            request.reply()
        })
        defer { server.shutdown() }
        let client = server.makeClient()

        let response = try await client.send(XPCMessage(route: "test.plain.ok"))
        #expect(response.string(key: XPCMessage.routeKey) != nil)
    }

    @Test
    func plainSendIgnoresCancellationAfterDispatch() async throws {
        // Server holds the reply behind a gate. The test cancels the task after
        // the message has been dispatched; if cancellation were honored, the task
        // would throw `CancellationError`. We then open the gate and verify the
        // task completes successfully — proving cancellation was ignored.
        let gate = Gate()
        let server = LocalXPCServer(handler: { request in
            Task {
                await gate.wait()
                request.reply()
            }
        })
        defer { server.shutdown() }
        let client = server.makeClient()

        let task = Task {
            try await client.send(XPCMessage(route: "test.plain.cancel"))
        }

        // Yield enough time for the message to dispatch and the server to enqueue
        // its waiter on `gate`.
        try await Task.sleep(for: .milliseconds(100))

        task.cancel()

        // Hold the reply so we can be sure the cancellation has propagated.
        try await Task.sleep(for: .milliseconds(100))

        // Release the server reply.
        await gate.open()

        // If cancellation were honored, this would throw CancellationError.
        let response = try await task.value
        #expect(response.string(key: XPCMessage.routeKey) != nil)
    }

    @Test
    func plainSendHonorsCancellationBeforeDispatch() async throws {
        let server = LocalXPCServer(handler: { request in
            request.reply()
        })
        defer { server.shutdown() }
        let client = server.makeClient()

        let task = Task {
            // Pre-cancel before reaching `client.send`.
            try await Task.sleep(for: .milliseconds(50))
            try await client.send(XPCMessage(route: "test.plain.precancel"))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}

// MARK: - Test helpers

/// In-process XPC listener that hands incoming requests to a test handler.
///
/// Every received request is retained by the server until ``shutdown()`` so
/// XPC does not invalidate the underlying message while a test is deliberately
/// withholding a reply.
private final class LocalXPCServer: @unchecked Sendable {
    private let listener: xpc_connection_t
    private let queue: DispatchQueue
    private let pending = Mutex<[XPCRequest]>([])

    init(handler: @escaping @Sendable (XPCRequest) -> Void) {
        let queue = DispatchQueue(label: "test.server.\(UUID().uuidString)")
        self.queue = queue
        self.listener = xpc_connection_create(nil, queue)
        let pending = self.pending

        xpc_connection_set_event_handler(self.listener) { event in
            guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
            let peer = event
            xpc_connection_set_event_handler(peer) { msg in
                guard xpc_get_type(msg) == XPC_TYPE_DICTIONARY else { return }
                let request = XPCRequest(message: msg, peer: peer)
                pending.modify { $0.append(request) }
                handler(request)
            }
            xpc_connection_activate(peer)
        }
        xpc_connection_activate(self.listener)
    }

    func makeClient() -> XPCClient {
        let endpoint = xpc_endpoint_create(self.listener)
        let connection = xpc_connection_create_from_endpoint(endpoint)
        return XPCClient(connection: connection, label: "test")
    }

    func shutdown() {
        pending.set([])
        xpc_connection_cancel(self.listener)
    }
}

/// A request received by `LocalXPCServer`. Use ``reply()`` to send back a
/// well-formed XPC reply that the client's `send_message_with_reply` callback
/// will receive.
private struct XPCRequest: @unchecked Sendable {
    let message: xpc_object_t
    let peer: xpc_connection_t

    func reply() {
        guard let reply = xpc_dictionary_create_reply(message) else { return }
        xpc_dictionary_set_string(reply, XPCMessage.routeKey, "reply")
        xpc_connection_send_message(peer, reply)
    }
}

/// Minimal thread-safe single-value cell. Used to flip server behavior mid-test
/// without dragging in additional async machinery.
private final class Mutex<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) { self.value = value }

    func get() -> T {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ new: T) {
        lock.lock(); defer { lock.unlock() }
        value = new
    }

    func modify(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&value)
    }
}

/// One-shot async gate. Wait suspends until ``open()`` is called; after that,
/// every wait returns immediately.
private actor Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = continuations
        continuations.removeAll()
        for c in waiters { c.resume() }
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }

    fileprivate func error() -> Error? {
        switch self {
        case .success: return nil
        case .failure(let e): return e
        }
    }
}

#endif
