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
import Synchronization

/// Represents a long-lived connection to an XPC service on the client side.
///
/// Obtain one via `XPCClient.openSession()`. The disconnect handler is
/// installed at initialisation time, before the first `send()`, so there is
/// no window in which a server crash goes undetected.
public final class XPCClientSession: Sendable {
    private let client: XPCClient
    private let handlers: Mutex<[@Sendable () async -> Void]> = Mutex([])

    init(client: XPCClient) {
        self.client = client
        client.setDisconnectHandler { [weak self] in
            guard let self else { return }
            let snapshot = self.handlers.withLock { $0 }
            Task { for handler in snapshot { await handler() } }
        }
    }

    /// Register a handler to be called when the server disconnects.
    public func onDisconnect(_ handler: @Sendable @escaping () async -> Void) {
        handlers.withLock { $0.append(handler) }
    }

    /// Send a message over the persistent connection.
    @discardableResult
    public func send(_ message: XPCMessage, responseTimeout: Duration? = nil) async throws -> XPCMessage {
        try await client.send(message, responseTimeout: responseTimeout)
    }

    /// Cancel the underlying connection.
    public func close() { client.close() }
}

#endif
