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

/// Validates and resolves the MTU of a network attachment.
public enum NetworkMTU {
    /// The MTU values an attachment accepts.
    public static let validRange: ClosedRange<UInt32> = 1280...65535

    /// The MTU used when nothing else sets one. Callers get it through ``resolve(config:)``.
    // https://github.com/apple/containerization/pull/38
    static let defaultValue = validRange.lowerBound

    /// Parses and validates an MTU.
    ///
    /// - Parameters:
    ///   - value: The text to parse.
    ///   - source: Where the value came from, added to the error when it comes from somewhere other than a flag.
    /// - Throws: `.invalidArgument` if `value` is not a number in ``validRange``.
    public static func parse(_ value: String, source: String? = nil) throws -> UInt32 {
        guard let mtu = UInt32(value), validRange.contains(mtu) else {
            let suffix = source.map { " (from \($0))" } ?? ""
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid mtu value '\(value)': must be between \(validRange.lowerBound) and \(validRange.upperBound)\(suffix)"
            )
        }
        return mtu
    }

    /// Picks the MTU for an attachment that does not set its own.
    ///
    /// - Parameter config: The `[network] mtu` value from `config.toml`, if any.
    /// - Throws: `.invalidArgument` if `config` is not a valid MTU.
    public static func resolve(config: Int?) throws -> UInt32 {
        try config.map { try parse(String($0), source: "[network] mtu in config.toml") } ?? defaultValue
    }
}
