//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

/// Metadata fields for resources.
public struct ResourceMetadata: Sendable, Codable, Equatable {
    /// Creation timestamp for the resource.
    public var createdAt: Date?

    public init(createdAt: Date?) {
        self.createdAt = createdAt
    }
}

/// Protocol for resources that have common metadata fields.
public protocol HasMetadata {
    var metadata: ResourceMetadata { get set }
}

extension DateFormatter {
    /// A date formatter for ISO 8601 dates with fractional seconds.
    public static var metadataFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
