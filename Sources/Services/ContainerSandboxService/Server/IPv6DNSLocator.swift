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

import ContainerizationExtras
import Foundation
import Logging

public struct IPv6DNSProxyLocator {
    public static func findDNSProxy(scProperties: [String: [String: Any]], ipv6Prefix: CIDRv6, log: Logger) -> IPv6Address? {
        for (key, ipv6Properties) in scProperties {
            log.debug("finding DNS proxy", metadata: ["key": "\(key)"])
            guard let ipv6Addresses = ipv6Properties["Addresses"] as? [CFString] else {
                log.warning("skipping invalid property", metadata: ["name": "Addresses"])
                continue
            }
            guard let ipv6Flags = ipv6Properties["Flags"] as? [CFNumber] else {
                log.warning("skipping invalid property", metadata: ["name": "Flags"])
                continue
            }
            guard let prefixes = ipv6Properties["PrefixLength"] as? [CFNumber] else {
                log.warning("skipping invalid property", metadata: ["name": "PrefixLength"])
                continue
            }

            let prefixIndex = (0..<ipv6Addresses.count)
                .filter {
                    let candidateText = "\(ipv6Addresses[$0])/\(prefixes[$0])"
                    guard let candidate = try? CIDRv6(candidateText) else {
                        return false
                    }
                    return ipv6Prefix.contains(candidate.lower) && ipv6Prefix.contains(candidate.upper)
                }
                .first

            guard prefixIndex != nil else {
                log.debug("IPv6 prefix not found", metadata: ["cidrv6": "\(ipv6Prefix)"])
                continue
            }

            let flagsIndex = (0..<ipv6Addresses.count)
                .filter {
                    guard let flags = ipv6Flags[$0] as? Int else {
                        return false
                    }
                    return flags == 1088
                }
                .first

            guard let flagsIndex else {
                log.debug("IPv6 prefix found with non-secured flags", metadata: ["cidrv6": "\(ipv6Prefix)"])
                continue
            }

            guard let dnsAddress = try? IPv6Address("\(ipv6Addresses[flagsIndex])") else {
                log.debug("cannot create DNS address for IPv6 prefix", metadata: ["cidrv6": "\(ipv6Prefix)"])
                continue
            }

            return dnsAddress
        }

        return nil
    }
}
