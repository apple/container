//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

public struct XPCClient: Sendable {
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

    /// Send the provided message to the service.
    @discardableResult
    public func send(_ message: XPCMessage, responseTimeout: Duration? = nil) async throws -> XPCMessage {
        try await withThrowingTaskGroup(of: XPCMessage.self, returning: XPCMessage.self) { group in
            if let responseTimeout {
                group.addTask {
                    try await Task.sleep(for: responseTimeout)
                    let route = message.string(key: XPCMessage.routeKey) ?? "nil"
                    throw ContainerizationError(.internalError, message: "XPC timeout for request to \(self.service)/\(route)")
                }
            }

            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    xpc_connection_send_message_with_reply(self.connection, message.underlying, nil) { reply in
                        do {
                            let message = try self.parseReply(reply)
                            cont.resume(returning: message)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
            }

            let response = try await group.next()
            // once one task has finished, cancel the rest.
            group.cancelAll()
            // we don't really care about the second error here
            // as it's most likely a `CancellationError`.
            try? await group.waitForAll()

            guard let response else {
                throw ContainerizationError(.invalidState, message: "failed to receive XPC response")
            }
            return response
        }
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

#endif
