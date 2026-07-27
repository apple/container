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
            lineCount += Self.countLines(in: chunk, precedingChunk: chunks.last)
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

        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return Array(lines.suffix(n))
    }

    private static func countLines(in chunk: Data, precedingChunk: Data?) -> Int {
        var count = 0
        var previous: UInt8?
        for byte in chunk {
            if byte != Self.newline, previous == nil || previous == Self.newline {
                count += 1
            }
            previous = byte
        }

        if let last = chunk.last, last != Self.newline, let first = precedingChunk?.first, first != Self.newline {
            count -= 1
        }
        return count
    }

    private static func followFile(fh: FileHandle) async throws {
        _ = try fh.seekToEnd()
        let stream = AsyncStream<String> { cont in
            fh.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    do {
                        _ = try fh.seekToEnd()  // To continue streaming existing truncated log files
                    } catch {
                        fh.readabilityHandler = nil
                        cont.finish()
                        return
                    }
                }
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    var lines = str.components(separatedBy: .newlines)
                    lines = lines.filter { !$0.isEmpty }
                    for line in lines {
                        cont.yield(line)
                    }
                }
            }
        }

        for await line in stream {
            print(line)
        }
    }
}
