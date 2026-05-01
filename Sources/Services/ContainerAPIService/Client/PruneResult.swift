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

/// The outcome of a prune operation on containers, images, volumes, or networks.
public struct PruneResult: Sendable {
    public struct Failure: Sendable {
        public let id: String
        public let error: any Error

        public init(id: String, error: any Error) {
            self.id = id
            self.error = error
        }
    }

    public let pruned: [String]

    public let failed: [Failure]

    public let reclaimedBytes: UInt64

    public init(pruned: [String], failed: [Failure], reclaimedBytes: UInt64) {
        self.pruned = pruned
        self.failed = failed
        self.reclaimedBytes = reclaimedBytes
    }
}
