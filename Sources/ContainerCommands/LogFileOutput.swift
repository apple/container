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

/// Writes log file data while preserving the stored byte stream.
struct LogFileOutput {
    /// Writes all requested log data and optionally continues streaming appended bytes.
    static func write(
        fh: FileHandle,
        n: Int?,
        follow: Bool,
        output: FileHandle = .standardOutput
    ) async throws {
        if let n {
            try writeTail(fh: fh, lineCount: n, output: output)
        } else {
            try writeAll(fh: fh, output: output)
        }

        if follow {
            try await followFile(fh: fh, output: output)
        }
    }

    /// Writes existing raw log data without binding output to a specific file handle.
    static func write(data: Data, n: Int?, output: FileHandle = .standardOutput) {
        let selected = n.map { tailData(data, lineCount: $0) } ?? data
        if !selected.isEmpty {
            output.write(selected)
        }
    }

    /// Returns the final `lineCount` log records from `data`.
    static func tailData(_ data: Data, lineCount: Int) -> Data {
        guard lineCount != 0 else {
            return Data()
        }
        guard lineCount > 0 else {
            return data
        }

        var index = data.endIndex
        if index > data.startIndex, data[data.index(before: index)] == LogByte.lineFeed {
            index = data.index(before: index)
        }

        var foundLines = 0
        while index > data.startIndex {
            let previous = data.index(before: index)
            if data[previous] == LogByte.lineFeed {
                foundLines += 1
                if foundLines == lineCount {
                    return Data(data[data.index(after: previous)..<data.endIndex])
                }
            }
            index = previous
        }

        return data
    }

    private static func writeTail(
        fh: FileHandle,
        lineCount: Int,
        output: FileHandle
    ) throws {
        guard lineCount != 0 else {
            return
        }
        guard lineCount > 0 else {
            try writeAll(fh: fh, output: output)
            return
        }

        let size = try fh.seekToEnd()
        var offset = size
        var buffer = Data()

        while offset > 0, countedLines(in: buffer) <= lineCount {
            let readSize = min(1024, offset)
            offset -= readSize
            try fh.seek(toOffset: offset)
            let data = fh.readData(ofLength: Int(readSize))
            buffer.insert(contentsOf: data, at: 0)
        }

        let data = tailData(buffer, lineCount: lineCount)
        if !data.isEmpty {
            output.write(data)
        }
    }

    private static func writeAll(
        fh: FileHandle,
        output: FileHandle
    ) throws {
        guard let data = try fh.readToEnd(), !data.isEmpty else {
            return
        }
        output.write(data)
    }

    private static func followFile(
        fh: FileHandle,
        output: FileHandle
    ) async throws {
        _ = try? fh.seekToEnd()
        let stream = AsyncStream<Data> { continuation in
            fh.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    do {
                        _ = try handle.seekToEnd()
                    } catch {
                        handle.readabilityHandler = nil
                        continuation.finish()
                    }
                    return
                }
                continuation.yield(data)
            }
            continuation.onTermination = { _ in
                fh.readabilityHandler = nil
            }
        }

        for await data in stream {
            output.write(data)
        }
    }

    private static func countedLines(in data: Data) -> Int {
        guard !data.isEmpty else {
            return 0
        }
        let separatorCount = data.reduce(0) { count, byte in
            byte == LogByte.lineFeed ? count + 1 : count
        }
        if data.last == LogByte.lineFeed {
            return separatorCount
        }
        return separatorCount + 1
    }
}

private enum LogByte {
    static let lineFeed = UInt8(ascii: "\n")
}
