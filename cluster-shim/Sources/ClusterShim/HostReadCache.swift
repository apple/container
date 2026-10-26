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
import Synchronization

/// Reads host blobs in large windows and keeps the most recent ones, so
/// containerd's 32 KiB unpack reads turn into a few large host requests.
/// Blob sizes are cached too; blobs are immutable.
final class HostReadCache: Sendable {
    let host: any HostStore
    let windowSize: Int
    let maxWindows: Int
    private let state = Mutex(State())

    private struct Window {
        var digest: String
        var offset: Int64
        var data: Data
    }

    private struct State {
        var windows: [Window] = []
        var sizes: [String: Int64] = [:]
    }

    init(host: any HostStore, windowSize: Int = 4 << 20, maxWindows: Int = 8) {
        self.host = host
        self.windowSize = windowSize
        self.maxWindows = maxWindows
    }

    /// Returns a blob's size, asking the host only the first time.
    func size(digest: String) async throws -> Int64 {
        if let size = state.withLock({ $0.sizes[digest] }) {
            return size
        }
        let size = try await host.size(digest: digest)
        state.withLock { $0.sizes[digest] = size }
        return size
    }

    /// Returns up to `length` bytes at `offset`, stopping at the end of the
    /// window that holds `offset`. Callers keep reading for the rest.
    func read(digest: String, offset: Int64, length: Int) async throws -> Data {
        if let data = cached(digest: digest, offset: offset, length: length) {
            return data
        }
        let size = try await self.size(digest: digest)
        let windowLength = Int(min(Int64(windowSize), size - offset))
        guard windowLength > 0 else {
            return Data()
        }
        let data = try await host.read(digest: digest, offset: offset, length: windowLength)
        state.withLock { state in
            state.windows.append(Window(digest: digest, offset: offset, data: data))
            if state.windows.count > maxWindows {
                state.windows.removeFirst()
            }
        }
        return Data(data.prefix(length))
    }

    private func cached(digest: String, offset: Int64, length: Int) -> Data? {
        state.withLock { state in
            for window in state.windows where window.digest == digest {
                let start = offset - window.offset
                guard start >= 0, start < Int64(window.data.count) else {
                    continue
                }
                let lower = window.data.startIndex + Int(start)
                let upper = min(lower + length, window.data.endIndex)
                return Data(window.data[lower..<upper])
            }
            return nil
        }
    }
}
