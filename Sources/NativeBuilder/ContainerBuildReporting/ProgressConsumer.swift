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

/// Protocol for consuming and displaying build progress events.
///
/// Design rationale:
/// - Protocol-based design allows for different output formats
/// - Async/await support for streaming events
/// - Flexible configuration for different environments
/// - Built-in statistics tracking for all consumers
public protocol ProgressConsumer: Sendable {
    /// Configuration for the progress consumer
    associatedtype Configuration: Sendable

    /// Initialize with configuration
    init(configuration: Configuration)

    /// Consume events from the reporter and display progress
    func consume(reporter: Reporter) async throws

    /// Handle a single event (for testing or custom implementations)
    func handle(_ event: BuildEvent) async throws

    /// Get the accumulated build statistics
    func getStatistics() -> BuildStatistics

    /// Get all accumulated events
    func getEvents() -> [BuildEvent]
}
