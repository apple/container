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

/// Validates and resolves the MTU of a network and its attachments.
public enum NetworkMTU {
    /// The MTU values a network or an attachment accepts.
    public static let validRange: ClosedRange<UInt32> = 1280...65535

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

    /// Picks the MTU for a new network.
    ///
    /// - Parameters:
    ///   - network: The MTU the network was created with, if any.
    ///   - config: The `[network] mtu` value from `config.toml`, if any.
    /// - Returns: `network`, else `config`, else `nil` to leave the network at its plugin's default.
    /// - Throws: `.invalidArgument` if `config` is used and is not a valid MTU.
    public static func resolve(network: UInt32?, config: Int?) throws -> UInt32? {
        if let network {
            return network
        }
        return try config.map { try parse(String($0), source: "[network] mtu in config.toml") }
    }

    /// Checks that an attachment does not send frames larger than its network carries.
    ///
    /// - Parameters:
    ///   - attachment: The MTU the attachment asks for, if any.
    ///   - network: The MTU of the network, if it has one.
    ///   - networkId: The network, for the error message.
    /// - Throws: `.invalidArgument` if `attachment` is larger than `network`.
    public static func check(attachment: UInt32?, network: UInt32?, networkId: String) throws {
        guard let attachment, let network, attachment > network else {
            return
        }
        throw ContainerizationError(
            .invalidArgument,
            message: "invalid mtu value '\(attachment)': must not exceed the MTU \(network) of network \(networkId)"
        )
    }
}
