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

import ContainerXPC
import Foundation
import Testing

private final class HeldReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var replies = [xpc_object_t]()

    func hold(_ reply: xpc_object_t) {
        lock.withLock { replies.append(reply) }
    }
}

struct XPCClientTests {
    private func makeClient() -> (client: XPCClient, listener: xpc_connection_t) {
        let heldReplies = HeldReplies()
        let listener = xpc_connection_create(nil, nil)
        xpc_connection_set_event_handler(listener) { connection in
            guard xpc_get_type(connection) == XPC_TYPE_CONNECTION else { return }
            nonisolated(unsafe) let peer = connection
            xpc_connection_set_event_handler(peer) { request in
                guard xpc_get_type(request) == XPC_TYPE_DICTIONARY else { return }
                let route = XPCMessage(object: request).string(key: XPCMessage.routeKey)
                guard let reply = xpc_dictionary_create_reply(request) else { return }
                if route == "reply" {
                    xpc_connection_send_message(peer, reply)
                } else {
                    heldReplies.hold(reply)
                }
            }
            xpc_connection_activate(peer)
        }
        xpc_connection_activate(listener)

        let endpoint = xpc_endpoint_create(listener)
        let connection = xpc_connection_create_from_endpoint(endpoint)
        return (XPCClient(connection: connection, label: "anonymous-test"), listener)
    }

    @Test func timedOutRequestLeavesConnectionUsable() async throws {
        let (client, listener) = makeClient()
        defer {
            client.close()
            xpc_connection_cancel(listener)
        }

        do {
            _ = try await client.send(XPCMessage(route: "no-reply"), responseTimeout: .milliseconds(100))
            Issue.record("request unexpectedly completed")
        } catch {
            #expect(String(describing: error).contains("XPC timeout"))
        }

        _ = try await client.send(XPCMessage(route: "reply"), responseTimeout: .seconds(2))
    }

    @Test func cancellingRequestLeavesConnectionUsable() async throws {
        let (client, listener) = makeClient()
        defer {
            client.close()
            xpc_connection_cancel(listener)
        }

        let request = Task {
            try await client.send(XPCMessage(route: "no-reply"))
        }
        try await Task.sleep(for: .milliseconds(100))
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("cancelled request unexpectedly completed")
        } catch is CancellationError {
            // Expected: cancelling the task resumes the outstanding request.
        }

        _ = try await client.send(XPCMessage(route: "reply"), responseTimeout: .seconds(2))
    }
}
