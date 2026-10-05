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
import Foundation
import Testing

@testable import ContainerXPC

struct XPCMessageReplyTests {
    /// A locally-created dictionary was never received over a connection,
    /// so libxpc provides no reply context — the exact shape of a
    /// fire-and-forget attack message.
    @Test func locallyCreatedMessageHasNoReplyContext() {
        let message = XPCMessage(route: "com.apple.container.test/none")
        #expect(message.canReply == false)
    }

    /// Regression test for the `xpc_dictionary_create_reply!` trap at
    /// XPCMessage.swift:60. On buggy code this line SIGTRAPs (test host
    /// crashes = FAIL); on fixed code it returns a usable dictionary.
    @Test func replyToMessageWithoutReplyContextDoesNotTrap() {
        let message = XPCMessage(route: "com.apple.container.test/none")
        let reply = message.reply()
        reply.set(key: XPCMessage.errorKey, value: "sentinel")
        #expect(reply.string(key: XPCMessage.errorKey) == "sentinel")
    }

    /// The normal path is unaffected: reply dictionaries remain fully usable
    /// key-value stores.
    @Test func replyDictionaryRoundTripsKeys() {
        let message = XPCMessage(route: "com.apple.container.test/echo")
        let reply = message.reply()
        reply.set(key: "k", value: "v")
        #expect(reply.string(key: "k") == "v")
    }

    /// End-to-end shape of the reported attack: a dictionary delivered
    /// fire-and-forget via `xpc_connection_send_message` must neither trap
    /// in `reply()` nor report reply context via `canReply`.
    @Test func fireAndForgetDeliveryHasNoReplyContext() {
        let lock = NSLock()
        var receivedMsg: xpc_object_t?
        let sema = DispatchSemaphore(value: 0)

        let queue = DispatchQueue(label: "com.apple.container.test.listener")
        let listener = xpc_connection_create(nil, queue)
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            xpc_connection_set_event_handler(peer) { object in
                guard xpc_get_type(object) == XPC_TYPE_DICTIONARY else { return }
                lock.withLock { receivedMsg = object }
                sema.signal()
            }
            xpc_connection_activate(peer)
        }
        xpc_connection_activate(listener)
        defer { xpc_connection_cancel(listener) }

        let endpoint = xpc_endpoint_create(listener)
        let client = xpc_connection_create_from_endpoint(endpoint)
        xpc_connection_set_event_handler(client) { _ in }
        xpc_connection_activate(client)
        defer { xpc_connection_cancel(client) }

        let outgoing = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(outgoing, XPCMessage.routeKey, "com.apple.container.test/none")
        xpc_connection_send_message(client, outgoing)

        #expect(sema.wait(timeout: .now() + 10) == .success)
        let inbound = lock.withLock { receivedMsg }
        #expect(inbound != nil)
        guard let inbound else { return }

        let inboundMessage = XPCMessage(object: inbound)
        #expect(inboundMessage.canReply == false)
        let reply = inboundMessage.reply()
        reply.set(key: XPCMessage.errorKey, value: "sentinel")
        #expect(reply.string(key: XPCMessage.errorKey) == "sentinel")
    }
}
#endif
