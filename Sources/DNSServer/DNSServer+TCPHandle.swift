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

/// Tracks the timestamp of the last fully-processed DNS message on a TCP connection.
/// The idle watchdog reads this to decide when to close a stale connection.
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
    /// Handles a single inbound TCP DNS connection.
    ///
    /// DNS over TCP (RFC 1035 §4.2.2) prefixes every message with a 2-byte big-endian
    /// length field. Bytes are accumulated until a complete message is available, processed
    /// through the handler chain, and a length-prefixed response is written back.
    /// Multiple messages on the same connection (pipelining) are handled in order.
    ///
    /// The connection is closed when:
    /// - the client sends no data for `tcpIdleTimeout` between complete messages
    /// - a frame exceeding `maxTCPMessageSize` is received (indicates framing desync)
    /// - an unrecoverable I/O error occurs
    ///
    /// This method is `async` (not `async throws`) so per-connection failures never
    /// propagate up to the accept loop.
    func handleTCP(channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
        do {
            try await channel.executeThenClose { inbound, outbound in
                let activity = ConnectionActivity()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    // Watchdog: checks every second if the connection has gone idle.
                    // The timeout resets after each fully-processed message, so a client
                    // sending pipelined queries spaced a few seconds apart is unaffected.
                    group.addTask {
                        while await !activity.idle(after: self.tcpIdleTimeout) {
                            try await Task.sleep(for: .seconds(1))
                        }
                        self.log?.debug("TCP DNS: idle timeout, closing connection")
                        throw CancellationError()
                    }

                    // Read loop: accumulates bytes and dispatches complete DNS messages.
                    group.addTask {
                        var buffer = ByteBuffer()
                        for try await chunk in inbound {
                            await activity.ping()
                            buffer.writeImmutableBuffer(chunk)

                            // A single TCP segment may contain multiple back-to-back DNS messages.
                            while buffer.readableBytes >= 2 {
                                // Peek at the 2-byte length prefix without advancing the reader.
                                guard let msgLen = buffer.getInteger(
                                    at: buffer.readerIndex, as: UInt16.self
                                ) else { break }

                                // A value above our ceiling almost certainly means the framing
                                // is desynced — bail now rather than trying to read 60K bytes.
                                guard msgLen > 0, msgLen <= DNSServer.maxTCPMessageSize else {
                                    self.log?.error(
                                        "TCP DNS: unexpected frame size \(msgLen) bytes, closing connection")
                                    return
                                }

                                // Wait until the full payload has arrived before dispatching.
                                let needed = 2 + Int(msgLen)
                                guard buffer.readableBytes >= needed else { break }

                                buffer.moveReaderIndex(forwardBy: 2)
                                let msgSlice = buffer.readSlice(length: Int(msgLen))!
                                let msgData = Data(msgSlice.readableBytesView)

                                let responseData = try await self.processRaw(data: msgData)

                                // Reset the idle clock now that we have completed a round trip.
                                await activity.ping()

                                var out = ByteBuffer()
                                out.writeInteger(UInt16(responseData.count))
                                out.writeBytes(responseData)
                                try await outbound.write(out)
                            }
                        }
                    }

                    // First task to finish wins. The other is cancelled — any resulting
                    // CancellationError is intentionally ignored because no further work
                    // should happen on a connection that has already ended.
                    try await group.next()
                    group.cancelAll()
                }
            }
        } catch is CancellationError {
            // Expected on timeout — nothing to report.
        } catch {
            log?.warning("TCP DNS: connection error: \(error)")
        }
    }
}
