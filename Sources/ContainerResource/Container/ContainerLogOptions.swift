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

/// Options that refine how container logs are returned.
///
/// ``default`` is the zero-option equivalent to the original `logs(id:)`
/// behavior.
public struct ContainerLogOptions: Codable, Equatable, Sendable {
    /// If non-nil and non-negative, return only the last `tail` log lines.
    public let tail: Int?

    /// If non-nil, return log lines whose timestamp prefix is not older than
    /// this date. Logs without parseable timestamp prefixes cannot be filtered
    /// safely and cause the request to fail.
    public let since: Date?

    /// If non-nil, return log lines whose timestamp prefix is not newer than
    /// this date. Logs without parseable timestamp prefixes cannot be filtered
    /// safely and cause the request to fail.
    public let until: Date?

    /// If true, callers want timestamps preserved on returned log lines.
    ///
    /// The current log files are already returned as stored; this value is
    /// carried through the API boundary for callers that need stable timestamp
    /// behavior as the log implementation evolves.
    public let timestamps: Bool

    public static let `default` = ContainerLogOptions()

    public init(
        tail: Int? = nil,
        since: Date? = nil,
        until: Date? = nil,
        timestamps: Bool = false
    ) {
        self.tail = tail
        self.since = since
        self.until = until
        self.timestamps = timestamps
    }
}
