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

import Foundation
import NIOCore
import NIOPosix
import Synchronization

private actor ConnectionActivity {
    private var lastSeen: ContinuousClock.Instant

    init() {
        lastSeen = ContinuousClock.now
    }

    func ping() {
        lastSeen = ContinuousClock.now
    }

    func idle(after duration: Duration) -> Bool {
        ContinuousClock.now - lastSeen >= duration
    }
}

extension DNSServer {
    func handleTCP(channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
        do {
            try await channel.executeThenClose { inbound, outbound in
                let activity = ConnectionActivity()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let pollInterval = min(Duration.seconds(1), self.tcpIdleTimeout)
                        while true {
                            try await Task.sleep(for: pollInterval)
                            if await activity.idle(after: self.tcpIdleTimeout) { break }
                        }
                        self.log?.debug("TCP DNS: idle timeout, closing connection")
                        throw CancellationError()
                    }

                    group.addTask {
                        var buffer = ByteBuffer()
                        for try await chunk in inbound {
                            buffer.writeImmutableBuffer(chunk)

                            while buffer.readableBytes >= 2 {
                                guard let msgLen = buffer.getInteger(
                                    at: buffer.readerIndex, as: UInt16.self
                                ) else { break }

                                guard msgLen > 0, msgLen <= Self.maxTCPMessageSize else {
                                    self.log?.error(
                                        "TCP DNS: unexpected frame size \(msgLen) bytes, closing connection")
                                    return
                                }

                                let needed = 2 + Int(msgLen)
                                guard buffer.readableBytes >= needed else { break }

                                buffer.moveReaderIndex(forwardBy: 2)
                                guard let msgSlice = buffer.readSlice(length: Int(msgLen)) else { break }
                                let msgData = Data(msgSlice.readableBytesView)

                                let responseData = try await self.processRaw(data: msgData)

                                await activity.ping()

                                var out = ByteBuffer()
                                out.writeInteger(UInt16(responseData.count))
                                out.writeBytes(responseData)
                                try await outbound.write(out)
                            }
                        }
                    }

                    try await group.next()
                    group.cancelAll()
                }
            }
        } catch is CancellationError {
        } catch {
            log?.warning("TCP DNS: connection error: \(error)")
        }
    }
}
