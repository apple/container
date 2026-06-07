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

import ContainerizationError

/// Parsing helpers for `container machine set` arguments.
enum MachineSetArguments {
    /// Split `key=value` tokens, erroring on malformed entries.
    ///
    /// `omittingEmptySubsequences: false` keeps the trailing field so an
    /// empty value (e.g. `network=`, used to reset a list) parses as
    /// `("network", "")` rather than being dropped.
    static func pairs(_ rawArgs: [String]) throws -> [(key: String, value: String)] {
        try rawArgs.map { arg in
            let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw ContainerizationError(.invalidArgument, message: "invalid argument format '\(arg)'. Expected 'key=value'")
            }
            return (String(parts[0]), String(parts[1]))
        }
    }

    /// Collect a repeatable list setting (e.g. `network`, `kernel-arg`).
    ///
    /// Returns nil when the key is absent (leave the existing value
    /// unchanged); otherwise the non-empty values, where an all-empty set
    /// means reset to the default.
    static func list(forKey key: String, in pairs: [(key: String, value: String)]) -> [String]? {
        let matching = pairs.filter { $0.key == key }
        guard !matching.isEmpty else { return nil }
        return matching.map(\.value).filter { !$0.isEmpty }
    }

    /// The scalar (non-list) settings as a deduplicated map, with the given
    /// list keys removed.
    static func scalars(_ pairs: [(key: String, value: String)], excluding listKeys: Set<String>) -> [String: String] {
        Dictionary(
            pairs.filter { !listKeys.contains($0.key) }.map { ($0.key, $0.value) },
            uniquingKeysWith: { _, last in last }
        )
    }
}
