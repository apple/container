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
import Testing

@testable import ContainerResource

struct NetworkMTUTests {
    private static let lower = NetworkMTU.validRange.lowerBound
    private static let upper = NetworkMTU.validRange.upperBound

    // The only place the range is restated: it is what the rest of these tests are derived from.
    @Test
    func validRangeIsPinned() {
        #expect(NetworkMTU.validRange == 1280...65535)
    }

    // MARK: - parse

    @Test(arguments: [lower, upper])
    func parseAcceptsValuesInRange(value: UInt32) throws {
        #expect(try NetworkMTU.parse(String(value)) == value)
    }

    @Test(arguments: [String(lower - 1), String(upper + 1), "abc", "", "-1", "1500.5"])
    func parseRejectsOtherValues(value: String) {
        #expect {
            _ = try NetworkMTU.parse(value)
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.isCode(.invalidArgument)
                && error.description.contains("invalid mtu value '\(value)': must be between \(Self.lower) and \(Self.upper)")
        }
    }

    @Test
    func parseNamesTheSourceWhenGiven() {
        #expect {
            _ = try NetworkMTU.parse("1", source: "somewhere")
        } throws: { error in
            String(describing: error).contains("(from somewhere)")
        }
    }

    // MARK: - resolve

    @Test
    func resolveLeavesTheNetworkAtItsPluginDefault() throws {
        #expect(try NetworkMTU.resolve(network: nil, config: nil) == nil)
    }

    @Test
    func resolveUsesTheConfiguredValue() throws {
        #expect(try NetworkMTU.resolve(network: nil, config: 1400) == 1400)
    }

    @Test
    func resolvePrefersTheNetworkValue() throws {
        #expect(try NetworkMTU.resolve(network: 9000, config: 1400) == 9000)
    }

    @Test
    func resolveIgnoresAnInvalidConfigWhenTheNetworkSetsItsOwn() throws {
        #expect(try NetworkMTU.resolve(network: 9000, config: 100) == 9000)
    }

    @Test(arguments: [Int(lower) - 1, Int(upper) + 1, -1])
    func resolveRejectsAnInvalidConfig(config: Int) {
        #expect {
            _ = try NetworkMTU.resolve(network: nil, config: config)
        } throws: { error in
            let description = String(describing: error)
            return description.contains("invalid mtu value '\(config)'") && description.contains("[network] mtu")
        }
    }

    // MARK: - check

    @Test(arguments: [(UInt32?.none, UInt32?.none), (1400, nil), (nil, 1400), (1400, 1400), (1280, 9000)] as [(UInt32?, UInt32?)])
    func checkAcceptsAnAttachmentWithinItsNetwork(attachment: UInt32?, network: UInt32?) throws {
        try NetworkMTU.check(attachment: attachment, network: network, networkId: "foo")
    }

    @Test
    func checkRejectsAnAttachmentAboveItsNetwork() {
        #expect {
            try NetworkMTU.check(attachment: 9000, network: 1500, networkId: "foo")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.isCode(.invalidArgument)
                && error.description.contains("invalid mtu value '9000': must not exceed the MTU 1500 of network foo")
        }
    }
}
