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
import GRPCCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// Returns a file's modification time with nanosecond precision. Foundation's
/// file attributes round it to milliseconds on Linux.
func modificationTime(path: String) throws -> Date {
    var info = stat()
    guard stat(path, &info) == 0 else {
        throw RPCError(code: .notFound, message: "stat \(path): \(String(cString: strerror(errno)))")
    }
    #if canImport(Darwin)
    let time = info.st_mtimespec
    #else
    let time = info.st_mtim
    #endif
    return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
}

/// Writes a time to a file as nanoseconds since 1970.
func writeTimestamp(_ date: Date, to url: URL) throws {
    let nanoseconds = Int64(date.timeIntervalSince1970 * 1_000_000_000)
    try Data(String(nanoseconds).utf8).write(to: url)
}

/// Reads a time written by `writeTimestamp`.
func readTimestamp(from url: URL) throws -> Date {
    let text = try String(contentsOf: url, encoding: .utf8)
    guard let nanoseconds = Int64(text) else {
        throw RPCError(code: .internalError, message: "invalid timestamp in \(url.path)")
    }
    return Date(timeIntervalSince1970: TimeInterval(nanoseconds) / 1_000_000_000)
}
