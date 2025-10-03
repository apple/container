//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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
import Logging
import os
import Synchronization

public struct XPCServer: Sendable {
    public typealias RouteHandler = @Sendable (XPCMessage) async throws -> XPCMessage

    private let routes: [String: RouteHandler]
    // Access to `connection` is protected by a lock
    private nonisolated(unsafe) let connection: xpc_connection_t
    private let lock = NSLock()

    let log: Logging.Logger

    public init(identifier: String, routes: [String: RouteHandler], log: Logging.Logger) {
        let connection = xpc_connection_create_mach_service(
            identifier,
            nil,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )

        self.routes = routes
        self.connection = connection
        self.log = log
    }

    public init(connection: xpc_connection_t, routes: [String: RouteHandler], log: Logging.Logger) {
        self.routes = routes
        self.connection = connection
        self.log = log
    }

    public func listen() async throws {
        let connections = AsyncStream<xpc_connection_t> { cont in
            lock.withLock {
                xpc_connection_set_event_handler(self.connection) { object in
                    switch xpc_get_type(object) {
                    case XPC_TYPE_CONNECTION:
                        // `object` isn't used concurrently.
                        nonisolated(unsafe) let object = object
                        cont.yield(object)
                    case XPC_TYPE_ERROR:
                        if object.connectionError {
                            cont.finish()
                        }
                    default:
                        fatalError("unhandled xpc object type: \(xpc_get_type(object))")
                    }
                }
            }
        }

        defer {
            lock.withLock {
                xpc_connection_cancel(self.connection)
            }
        }

        lock.withLock {
            xpc_connection_activate(self.connection)
        }

        try await withThrowingDiscardingTaskGroup { group in
            for await conn in connections {
                // `conn` isn't used concurrently.
                nonisolated(unsafe) let conn = conn
                let added = group.addTaskUnlessCancelled { @Sendable in
                    try await self.handleClientConnection(connection: conn)
                    xpc_connection_cancel(conn)
                }

                if !added {
                    break
                }
            }

            group.cancelAll()
        }
    }

    func handleClientConnection(connection: xpc_connection_t) async throws {
        let replySent = Mutex(false)

        let objects = AsyncStream<xpc_object_t> { cont in
            xpc_connection_set_event_handler(connection) { object in
                switch xpc_get_type(object) {
                case XPC_TYPE_DICTIONARY:
                    // `object` isn't used concurrently.
                    nonisolated(unsafe) let object = object
                    cont.yield(object)
                case XPC_TYPE_ERROR:
                    if object.connectionError {
                        cont.finish()
                    }
                    if !(replySent.withLock({ $0 }) && object.connectionClosed) {
                        // When a xpc connection is closed, the framework sends a final XPC_ERROR_CONNECTION_INVALID message.
                        // We can ignore this if we know we have already handled the request.
                        self.log.error("xpc client handler connection error \(object.errorDescription ?? "no description")")
                    }
                default:
                    fatalError("unhandled xpc object type: \(xpc_get_type(object))")
                }
            }
        }
        defer {
            xpc_connection_cancel(connection)
        }

        xpc_connection_activate(connection)
        try await withThrowingDiscardingTaskGroup { group in
            // `connection` isn't used concurrently.
            nonisolated(unsafe) let connection = connection
            for await object in objects {
                // `object` isn't used concurrently.
                nonisolated(unsafe) let object = object
                let added = group.addTaskUnlessCancelled { @Sendable in
                    try await self.handleMessage(connection: connection, object: object)
                    replySent.withLock { $0 = true }
                }
                if !added {
                    break
                }
            }
            group.cancelAll()
        }
    }

    func handleMessage(connection: xpc_connection_t, object: xpc_object_t) async throws {
        guard let route = object.route else {
            log.error("empty route")
            return
        }

        if let handler = routes[route] {
            let message = XPCMessage(object: object)
            do {
                let response = try await handler(message)
                xpc_connection_send_message(connection, response.underlying)
            } catch let error as ContainerizationError {
                let reply = message.reply()
                log.error("handler for \(route) threw error \(error)")
                reply.set(error: error)
                xpc_connection_send_message(connection, reply.underlying)
            } catch {
                let reply = message.reply()
                log.error("handler for \(route) threw error \(error)")

                // Check if this is a VolumeError by looking at the error description
                let errorMessage = error.localizedDescription
                let errorTypeString = String(describing: type(of: error))
                if errorTypeString.contains("VolumeError") || errorMessage.contains("Volume") {
                    let err = ContainerizationError(.invalidArgument, message: errorMessage)
                    reply.set(error: err)
                } else {
                    let err = ContainerizationError(.unknown, message: String(describing: error))
                    reply.set(error: err)
                }
                xpc_connection_send_message(connection, reply.underlying)
            }
        }
    }
}

extension xpc_object_t {
    var route: String? {
        let croute = xpc_dictionary_get_string(self, XPCMessage.routeKey)
        guard let croute else {
            return nil
        }
        return String(cString: croute)
    }

    var connectionError: Bool {
        precondition(isError, "Not an error")
        return xpc_equal(self, XPC_ERROR_CONNECTION_INVALID) || xpc_equal(self, XPC_ERROR_CONNECTION_INTERRUPTED)
    }

    var connectionClosed: Bool {
        precondition(isError, "Not an error")
        return xpc_equal(self, XPC_ERROR_CONNECTION_INVALID)
    }

    var isError: Bool {
        xpc_get_type(self) == XPC_TYPE_ERROR
    }

    var errorDescription: String? {
        precondition(isError, "Not an error")
        let cstring = xpc_dictionary_get_string(self, XPC_ERROR_KEY_DESCRIPTION)
        guard let cstring else {
            return nil
        }
        return String(cString: cstring)
    }
}

#endif
