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
@preconcurrency import Foundation
import Logging
import Testing

@testable import ContainerXPC

@Suite(.timeLimit(.minutes(1)), .serialized)
struct XPCClientTests {
    @Test
    func replyBoxDeliversCancellationThatPrecedesContinuationStorage() async throws {
        let box = XPCReplyBox()
        box.resume { throw CancellationError() }

        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                box.store(continuation)
            }
            Issue.record("expected the pending cancellation to be delivered")
        } catch is CancellationError {
            // Expected.
        }
    }

    @Test
    func responseTimeoutReturnsWithinBound() async throws {
        let server = AnonymousXPCServer()
        defer { server.close() }

        let client = server.makeClient()
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await client.send(
                XPCMessage(route: "hang"),
                responseTimeout: .milliseconds(100)
            )
            Issue.record("expected send to time out")
        } catch let error as ContainerizationError {
            #expect(error.message.contains("XPC timeout for request to test.container.xpc/hang"))
            #expect(start.duration(to: clock.now) < .seconds(2))
        }
    }

    @Test
    func callerCancellationReturnsWithinBound() async throws {
        let server = AnonymousXPCServer()
        defer { server.close() }

        let client = server.makeClient()
        let request = Task {
            try await client.send(
                XPCMessage(route: "hang"),
                responseTimeout: .seconds(30)
            )
        }

        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let start = clock.now
        request.cancel()

        do {
            _ = try await request.value
            Issue.record("expected send to be cancelled")
        } catch is CancellationError {
            #expect(start.duration(to: clock.now) < .seconds(2))
        }
    }

    @Test
    func clientCanBeReusedAfterResponseTimeout() async throws {
        let server = AnonymousXPCServer()
        defer { server.close() }

        let client = server.makeClient()

        do {
            _ = try await client.send(
                XPCMessage(route: "hang"),
                responseTimeout: .milliseconds(100)
            )
            Issue.record("expected send to time out")
        } catch let error as ContainerizationError {
            #expect(error.message.contains("XPC timeout"))
        }

        let response = try await client.send(
            XPCMessage(route: "echo"),
            responseTimeout: .seconds(1)
        )
        #expect(response.string(key: "result") == "ok")
    }

    @Test
    func lateReplyAfterTimeoutIsIgnored() async throws {
        let server = AnonymousXPCServer()
        defer { server.close() }

        let client = server.makeClient()

        do {
            _ = try await client.send(
                XPCMessage(route: "hang"),
                responseTimeout: .milliseconds(100)
            )
            Issue.record("expected send to time out")
        } catch let error as ContainerizationError {
            #expect(error.message.contains("XPC timeout"))
        }

        #expect(server.replyToPendingRequests())
        try await Task.sleep(for: .milliseconds(50))

        let response = try await client.send(
            XPCMessage(route: "echo"),
            responseTimeout: .seconds(1)
        )
        #expect(response.string(key: "result") == "ok")
    }

    @Test
    func unknownRouteReturnsInvalidArgument() async throws {
        let listener = xpc_connection_create(nil, nil)
        let server = XPCServer(
            connection: listener,
            routes: [:],
            log: Logger(label: "test.container.xpc.unknown-route")
        )
        let serverTask = Task {
            try await server.listen()
        }
        defer {
            serverTask.cancel()
            xpc_connection_cancel(listener)
        }

        try await Task.sleep(for: .milliseconds(50))
        let endpoint = xpc_endpoint_create(listener)
        let client = XPCClient(
            connection: xpc_connection_create_from_endpoint(endpoint),
            label: "test.container.xpc"
        )

        do {
            _ = try await client.send(XPCMessage(route: "missing"))
            Issue.record("expected the server to reject an unknown route")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidArgument)
            #expect(error.message == "unknown route: missing")
        }
    }
}

private final class AnonymousXPCServer: @unchecked Sendable {
    private let listener: xpc_connection_t
    private let lock = NSLock()
    private var connections = [xpc_connection_t]()
    private var pendingRequests = [xpc_object_t]()

    init() {
        listener = xpc_connection_create(nil, nil)
        xpc_connection_set_event_handler(listener) { [weak self] object in
            switch xpc_get_type(object) {
            case XPC_TYPE_CONNECTION:
                self?.accept(connection: object)
            case XPC_TYPE_ERROR:
                break
            default:
                fatalError("unhandled xpc object type: \(xpc_get_type(object))")
            }
        }
        xpc_connection_activate(listener)
    }

    func makeClient() -> XPCClient {
        let endpoint = xpc_endpoint_create(listener)
        let connection = xpc_connection_create_from_endpoint(endpoint)
        return XPCClient(connection: connection, label: "test.container.xpc")
    }

    func close() {
        xpc_connection_cancel(listener)
        lock.withLock {
            for connection in connections {
                xpc_connection_cancel(connection)
            }
            connections.removeAll()
            pendingRequests.removeAll()
        }
    }

    func replyToPendingRequests() -> Bool {
        let requests = lock.withLock {
            let requests = pendingRequests
            pendingRequests.removeAll()
            return requests
        }
        guard let connection = lock.withLock({ connections.last }) else {
            return false
        }
        for request in requests {
            guard let reply = xpc_dictionary_create_reply(request) else {
                continue
            }
            xpc_dictionary_set_string(reply, "result", "late")
            xpc_connection_send_message(connection, reply)
        }
        return !requests.isEmpty
    }

    private func accept(connection: xpc_connection_t) {
        lock.withLock {
            connections.append(connection)
        }
        nonisolated(unsafe) let connection = connection
        xpc_connection_set_event_handler(connection) { [weak self] object in
            guard let self else {
                return
            }
            switch xpc_get_type(object) {
            case XPC_TYPE_DICTIONARY:
                let message = XPCMessage(object: object)
                switch message.string(key: XPCMessage.routeKey) {
                case "echo":
                    guard let reply = xpc_dictionary_create_reply(object) else {
                        return
                    }
                    xpc_dictionary_set_string(reply, "result", "ok")
                    xpc_connection_send_message(connection, reply)
                default:
                    self.lock.withLock {
                        self.pendingRequests.append(object)
                    }
                }
            case XPC_TYPE_ERROR:
                break
            default:
                fatalError("unhandled xpc object type: \(xpc_get_type(object))")
            }
        }
        xpc_connection_activate(connection)
    }
}
#endif
