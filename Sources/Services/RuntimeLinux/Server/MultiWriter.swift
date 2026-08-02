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

import Containerization
import Foundation

/// Fans container stdout/stderr out to one or more file handles (typically the
/// attached client stdio handle plus the on-disk container log).
///
/// Individual handle failures are isolated so a dead attached client (EPIPE)
/// cannot stop writes to the remaining handles.
final class MultiWriter: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [FileHandle]

    init(handles: [FileHandle]) {
        self.handles = handles
    }

    /// Returns the currently live handles. Intended for tests.
    var liveHandles: [FileHandle] {
        lock.lock()
        defer { lock.unlock() }
        return handles
    }

    func close() throws {
        lock.lock()
        let current = handles
        handles = []
        lock.unlock()

        var lastError: Error?
        var failures = 0
        for handle in current {
            do {
                try handle.close()
            } catch {
                failures += 1
                lastError = error
            }
        }
        if failures == current.count, let lastError {
            throw lastError
        }
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        var surviving: [FileHandle] = []
        surviving.reserveCapacity(handles.count)
        var lastError: Error?
        for handle in handles {
            do {
                try handle.write(contentsOf: data)
                surviving.append(handle)
            } catch {
                lastError = error
            }
        }
        handles = surviving
        if surviving.isEmpty, let lastError {
            throw lastError
        }
    }
}
