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

import Foundation
import Logging
import Synchronization
import Testing

@testable import ContainerBuild

struct BuilderResizeForwardingTests {
    /// A transient failure while reading the terminal size must be logged and
    /// must not stop resize forwarding for the rest of the build: a later signal
    /// with a changed size should still be forwarded.
    @Test func readSizeFailureIsLoggedAndForwardingContinues() async throws {
        let collector = CollectingLogHandler.Storage()
        var logger = Logger(label: "test") { _ in CollectingLogHandler(storage: collector) }
        logger.logLevel = .trace

        let readCount = Mutex(0)
        let sent = Mutex<[(rows: UInt16, cols: UInt16)]>([])

        let (signals, continuation) = AsyncStream.makeStream(of: Int32.self)

        let forwarder = Task {
            await Builder.forwardTerminalResize(
                signals: signals,
                readSize: {
                    let call = readCount.withLock { value -> Int in
                        value += 1
                        return value
                    }
                    switch call {
                    case 1: return (rows: 24, cols: 80)  // initial size
                    case 2: throw POSIXError(.EIO)  // transient failure
                    default: return (rows: 30, cols: 100)  // recovered, changed size
                    }
                },
                send: { rows, cols in
                    sent.withLock { $0.append((rows: rows, cols: cols)) }
                },
                logger: logger
            )
        }

        continuation.yield(SIGWINCH)  // triggers the failing read
        continuation.yield(SIGWINCH)  // triggers the recovered read
        continuation.finish()
        await forwarder.value

        let sentSizes = sent.withLock { $0 }
        #expect(sentSizes.count == 2)
        #expect(sentSizes.first.map { $0 == (rows: 24, cols: 80) } == true)
        #expect(sentSizes.last.map { $0 == (rows: 30, cols: 100) } == true)
        #expect(collector.errorMessages.contains { $0.contains("terminal resize") })
    }

    /// The forwarder must return once the signal stream finishes. In production
    /// the owning task cancels the signal handler, which finishes the stream, so
    /// the SIGWINCH watcher does not outlive the build.
    @Test func forwarderReturnsWhenSignalStreamFinishes() async throws {
        let sent = Mutex(0)
        let (signals, continuation) = AsyncStream.makeStream(of: Int32.self)

        let forwarder = Task {
            await Builder.forwardTerminalResize(
                signals: signals,
                readSize: { (rows: 24, cols: 80) },
                send: { _, _ in sent.withLock { $0 += 1 } },
                logger: Logger(label: "test") { _ in SwiftLogNoOpLogHandler() }
            )
        }

        continuation.finish()
        await forwarder.value  // returns only if the loop exited on stream finish

        // Only the initial size is sent; no signals were delivered.
        #expect(sent.withLock { $0 } == 1)
    }
}

/// Minimal `LogHandler` that records emitted error messages for assertions.
private struct CollectingLogHandler: LogHandler {
    final class Storage: Sendable {
        private let messages = Mutex<[String]>([])

        var errorMessages: [String] {
            messages.withLock { $0 }
        }

        func append(_ message: String) {
            messages.withLock { $0.append(message) }
        }
    }

    let storage: Storage
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        if level >= .error {
            storage.append(message.description)
        }
    }
}
