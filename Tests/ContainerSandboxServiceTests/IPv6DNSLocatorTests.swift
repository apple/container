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

import ContainerSandboxService
import ContainerizationExtras
import Foundation
import Logging
import Testing

@Suite("IPv6DNSProxyLocator Tests")
struct IPv6DNSProxyLocatorTests {
    let logger = Logger(label: "test")

    @Test("Finds DNS proxy when network matches prefix and has flags 1088")
    func findsMatchingDNSProxy() throws {
        let scProperties: [String: [String: Any]] = [
            "State:/Network/Interface/bridge100/IPv6": [
                "Addresses": [
                    "fe80::603e:5fff:fe94:4e64",
                    "fd97:7b15:d62e:75ac:4fa:6b2d:4f21:fd01",
                ] as CFArray,
                "Flags": [0, 1088] as CFArray,
                "PrefixLength": [64, 64] as CFArray,
            ]
        ]

        let prefix = try CIDRv6("fd97:7b15:d62e:75ac::/64")
        let result = IPv6DNSProxyLocator.findDNSProxy(
            scProperties: scProperties,
            ipv6Prefix: prefix,
            log: logger
        )

        #expect(result != nil)
        #expect(result?.description == "fd97:7b15:d62e:75ac:4fa:6b2d:4f21:fd01")
    }

    @Test("Returns nil when prefix does not match any network")
    func returnsNilWhenPrefixDoesNotMatch() throws {
        let scProperties: [String: [String: Any]] = [
            "State:/Network/Interface/bridge100/IPv6": [
                "Addresses": [
                    "fe80::603e:5fff:fe94:4e64",
                    "fd97:7b15:d62e:75ac:4fa:6b2d:4f21:fd01",
                ] as CFArray,
                "Flags": [0, 1088] as CFArray,
                "PrefixLength": [64, 64] as CFArray,
            ]
        ]

        let prefix = try CIDRv6("fd00:1234:5678::/64")
        let result = IPv6DNSProxyLocator.findDNSProxy(
            scProperties: scProperties,
            ipv6Prefix: prefix,
            log: logger
        )

        #expect(result == nil)
    }

    @Test("Returns nil when flags are not 1088")
    func returnsNilWhenFlagsAreWrong() throws {
        let scProperties: [String: [String: Any]] = [
            "State:/Network/Interface/bridge100/IPv6": [
                "Addresses": [
                    "fd97:7b15:d62e:75ac:4fa:6b2d:4f21:fd01"
                ] as CFArray,
                "Flags": [0] as CFArray,
                "PrefixLength": [64] as CFArray,
            ]
        ]

        let prefix = try CIDRv6("fd97:7b15:d62e:75ac::/64")
        let result = IPv6DNSProxyLocator.findDNSProxy(
            scProperties: scProperties,
            ipv6Prefix: prefix,
            log: logger
        )

        #expect(result == nil)
    }

    @Test("Returns nil when Addresses property is missing")
    func returnsNilWhenAddressesAreMissing() throws {
        let scProperties: [String: [String: Any]] = [
            "State:/Network/Interface/bridge100/IPv6": [
                "Flags": [0, 1088] as CFArray,
                "PrefixLength": [64, 64] as CFArray,
            ]
        ]

        let prefix = try CIDRv6("fd97:7b15:d62e:75ac::/64")
        let result = IPv6DNSProxyLocator.findDNSProxy(
            scProperties: scProperties,
            ipv6Prefix: prefix,
            log: logger
        )

        #expect(result == nil)
    }

    @Test("Returns nil when Flags property is missing")
    func returnsNilWhenFlagsAreMissing() throws {
        let scProperties: [String: [String: Any]] = [
            "State:/Network/Interface/bridge100/IPv6": [
                "Addresses": [
                    "fd97:7b15:d62e:75ac:4fa:6b2d:4f21:fd01"
                ] as CFArray,
                "PrefixLength": [64] as CFArray,
            ]
        ]

        let prefix = try CIDRv6("fd97:7b15:d62e:75ac::/64")
        let result = IPv6DNSProxyLocator.findDNSProxy(
            scProperties: scProperties,
            ipv6Prefix: prefix,
            log: logger
        )

        #expect(result == nil)
    }

    @Test("Returns nil when PrefixLength property is missing")
    func returnsNilWhenPrefixLengthIsMissing() throws {
        let scProperties: [String: [String: Any]] = [
            "State:/Network/Interface/bridge100/IPv6": [
                "Addresses": [
                    "fd97:7b15:d62e:75ac:4fa:6b2d:4f21:fd01"
                ] as CFArray,
                "Flags": [1088] as CFArray,
            ]
        ]

        let prefix = try CIDRv6("fd97:7b15:d62e:75ac::/64")
        let result = IPv6DNSProxyLocator.findDNSProxy(
            scProperties: scProperties,
            ipv6Prefix: prefix,
            log: logger
        )

        #expect(result == nil)
    }

    @Test("Finds DNS proxy across multiple interfaces")
    func findsProxyAcrossMultipleInterfaces() throws {
        let scProperties: [String: [String: Any]] = [
            "State:/Network/Interface/en0/IPv6": [
                "Addresses": [
                    "fe80::1"
                ] as CFArray,
                "Flags": [0] as CFArray,
                "PrefixLength": [64] as CFArray,
            ],
            "State:/Network/Interface/bridge100/IPv6": [
                "Addresses": [
                    "fe80::603e:5fff:fe94:4e64",
                    "fd97:7b15:d62e:75ac:4fa:6b2d:4f21:fd01",
                ] as CFArray,
                "Flags": [0, 1088] as CFArray,
                "PrefixLength": [64, 64] as CFArray,
            ],
        ]

        let prefix = try CIDRv6("fd97:7b15:d62e:75ac::/64")
        let result = IPv6DNSProxyLocator.findDNSProxy(
            scProperties: scProperties,
            ipv6Prefix: prefix,
            log: logger
        )

        #expect(result != nil)
        #expect(result?.description == "fd97:7b15:d62e:75ac:4fa:6b2d:4f21:fd01")
    }

    @Test("Returns nil when address cannot be parsed")
    func returnsNilWhenAddressCannotBeParsed() throws {
        let scProperties: [String: [String: Any]] = [
            "State:/Network/Interface/bridge100/IPv6": [
                "Addresses": [
                    "invalid-address"
                ] as CFArray,
                "Flags": [1088] as CFArray,
                "PrefixLength": [64] as CFArray,
            ]
        ]

        let prefix = try CIDRv6("fd97:7b15:d62e:75ac::/64")
        let result = IPv6DNSProxyLocator.findDNSProxy(
            scProperties: scProperties,
            ipv6Prefix: prefix,
            log: logger
        )

        #expect(result == nil)
    }
}
