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

import ContainerBuildIR
import Foundation

/// Manages filesystem snapshots during build execution.
///
/// The snapshotter is responsible for creating and managing filesystem
/// snapshots that represent the state at different points in the build.
public protocol Snapshotter: Sendable {
    /// Prepare a snapshot for use (e.g., mount it).
    ///
    /// - Parameter snapshot: The snapshot to prepare
    /// - Returns: The prepared snapshot
    func prepare(_ snapshot: Snapshot) async throws -> Snapshot

    /// Commit a snapshot, making it permanent. Returns a new Snapshot
    /// that is base + changes
    ///
    /// - Parameter snapshot: The snapshot to commit
    /// - Returns: The committed snapshot with final digest
    func commit(_ snapshot: Snapshot) async throws -> Snapshot

    /// Remove a snapshot.
    ///
    /// - Parameter snapshot: The snapshot to remove
    func remove(_ snapshot: Snapshot) async throws
}
