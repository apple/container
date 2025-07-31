//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

/// Central event hub for build progress reporting.
///
/// Design rationale:
/// - Actor-based for thread safety without manual locking
/// - AsyncStream for real-time event consumption
/// - Bounded buffer to prevent unbounded memory growth
/// - Single source of truth for all build events
public actor Reporter {
    private let continuation: AsyncStream<BuildEvent>.Continuation
    public nonisolated let stream: AsyncStream<BuildEvent>

    /// Initialize with a buffer size for the event stream
    public init(bufferSize: Int = 100) {
        (self.stream, self.continuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(bufferSize)
        )
    }

    /// Report a new event
    public func report(_ event: BuildEvent) {
        continuation.yield(event)
    }

    /// Finish the event stream (no more events will be reported)
    public func finish() {
        continuation.finish()
    }
}
