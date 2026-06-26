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
import ContainerXPC
import ContainerizationError
@preconcurrency import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
struct XPCClientTests {
    @Test
    func responseTimeoutReturnsWithinBound() async throws {
        let server = AnonymousXPCServer()
        defer { server.close() }

        let client = server.makeClient()
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await client.send(XPCMessage(route: "hang"), responseTimeout: .milliseconds(100))
            Issue.record("expected send to time out")
        } catch let error as ContainerizationError {
            let elapsed = start.duration(to: clock.now)
            #expect(error.code == .timeout)
            #expect(error.message.contains("XPC timeout for request to test.container.xpc/hang"))
            #expect(elapsed < .seconds(2))
        }
    }

    @Test
    func responseTimeoutHandlesMessagesWithoutRoute() async throws {
        let server = AnonymousXPCServer()
        defer { server.close() }

        let client = server.makeClient()

        do {
            _ = try await client.send(XPCMessage(object: xpc_dictionary_create_empty()), responseTimeout: .milliseconds(100))
            Issue.record("expected send to time out")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
            #expect(error.message.contains("XPC timeout for request to test.container.xpc/nil"))
        }
    }

    @Test
    func sendWithoutResponseTimeoutCompletesWhenServerReplies() async throws {
        let server = AnonymousXPCServer()
        defer { server.close() }

        let client = server.makeClient()
        let response = try await client.send(XPCMessage(route: "echo"))
        #expect(response.string(key: "result") == "ok")
    }

    @Test
    func clientCanBeReusedAfterResponseTimeout() async throws {
        let server = AnonymousXPCServer()
        defer { server.close() }

        let client = server.makeClient()

        do {
            _ = try await client.send(XPCMessage(route: "hang"), responseTimeout: .milliseconds(100))
            Issue.record("expected send to time out")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
        }

        let response = try await client.send(XPCMessage(route: "echo"), responseTimeout: .seconds(1))
        #expect(response.string(key: "result") == "ok")
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
                case "hang":
                    self.lock.withLock {
                        self.pendingRequests.append(object)
                    }
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
