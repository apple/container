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

/// Options that refine how `ContainerClient.logs(id:options:)` returns
/// container log file handles.
///
/// Both fields are optional / additive; ``default`` is the zero-value
/// equivalent to the original `logs(id:)` behavior.
public struct ContainerLogOptions: Sendable, Codable {
    /// If non-nil, log lines whose ISO-8601 timestamp prefix is older than
    /// this date are filtered out before the file handle is returned to the
    /// client. Lines without a parseable timestamp are passed through
    /// unchanged.
    public let since: Date?

    /// If true, the client wants timestamps preserved on the returned lines.
    /// At present this is a hint only — the daemon does not decorate raw log
    /// lines that lack a timestamp prefix; line decoration is a follow-up.
    public let timestamps: Bool

    public static let `default` = ContainerLogOptions(since: nil, timestamps: false)

    public init(since: Date? = nil, timestamps: Bool = false) {
        self.since = since
        self.timestamps = timestamps
    }
}
