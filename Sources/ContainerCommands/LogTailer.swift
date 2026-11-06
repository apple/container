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

import ContainerizationError
import Darwin
import Foundation

enum LogTailer {
    private static let chunkSize: UInt64 = 1024
    private static let newline = UInt8(ascii: "\n")

    static func tail(fh: FileHandle, n: Int?, follow: Bool) async throws {
        if let n {
            for line in try lastLines(fh: fh, n: n) {
                print(line)
            }
        } else {
            guard let data = try fh.readToEnd() else {
                return
            }
            guard let str = String(data: data, encoding: .utf8) else {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to convert container logs to utf8"
                )
            }
            print(str.trimmingCharacters(in: .newlines))
        }

        fflush(stdout)
        if follow {
            setbuf(stdout, nil)
            try await followFile(fh: fh)
        }
    }

    static func lastLines(fh: FileHandle, n: Int) throws -> [String] {
        guard n > 0 else {
            return []
        }

        var offset = try fh.seekToEnd()
        var chunks: [Data] = []
        var lineCount = 0

        while offset > 0, lineCount <= n {
            let readSize = min(Self.chunkSize, offset)
            offset -= readSize
            try fh.seek(toOffset: offset)

            let chunk = fh.readData(ofLength: Int(readSize))
            lineCount += Self.countNewlines(in: chunk)
            chunks.append(chunk)
        }

        var buffer = Data()
        for chunk in chunks.reversed() {
            buffer.append(chunk)
        }

        let decodable = buffer.drop { $0 & 0xC0 == 0x80 }
        guard let text = String(data: decodable, encoding: .utf8) else {
            return []
        }

        var lines = text.components(separatedBy: "\n")
        // A trailing newline terminates the final line rather than starting an empty one.
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return Array(lines.suffix(n))
    }

    private static func countNewlines(in chunk: Data) -> Int {
        var count = 0
        for byte in chunk where byte == Self.newline {
            count += 1
        }
        return count
    }

    private static func followFile(fh: FileHandle) async throws {
        _ = try fh.seekToEnd()
        let pending = LineBuffer()
        let stream = AsyncStream<String> { cont in
            fh.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    do {
                        _ = try fh.seekToEnd()  // To continue streaming existing truncated log files
                    } catch {
                        fh.readabilityHandler = nil
                        cont.finish()
                    }
                    return
                }
                for line in pending.appendAndTakeCompleteLines(data) {
                    cont.yield(line)
                }
            }
        }

        for await line in stream {
            print(line)
        }
    }

    /// Accumulates bytes across reads so only complete lines are emitted. A read can end
    /// mid-line or mid-UTF-8-sequence, so without this a fragment would print as a whole
    /// line and a split multi-byte character would discard the entire read.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func appendAndTakeCompleteLines(_ data: Data) -> [String] {
            lock.lock()
            defer { lock.unlock() }

            buffer.append(data)

            var lines: [String] = []
            var start = buffer.startIndex
            while let index = buffer[start...].firstIndex(of: LogTailer.newline) {
                lines.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = buffer.index(after: index)
            }
            if start > buffer.startIndex {
                buffer = Data(buffer[start...])
            }
            return lines
        }
    }
}
