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

import NIO

public struct SocketForwarderResult: Sendable {
    private let channel: any Channel

    public init(channel: Channel) {
        self.channel = channel
    }

    public var proxyAddress: SocketAddress? { self.channel.localAddress }

    public func close() {
        self.channel.eventLoop.execute {
            _ = channel.close()
        }
    }

    public func wait() async throws {
        try await self.channel.closeFuture.get()
    }
}
