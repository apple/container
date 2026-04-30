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

import ContainerPersistence
import ContainerizationError
import ContainerizationExtras

/// The URL scheme to be used for a HTTP request.
public enum RequestScheme: String, Sendable {
    case http = "http"
    case https = "https"

    case auto = "auto"

    public init(_ rawValue: String) throws {
        switch rawValue {
        case RequestScheme.http.rawValue:
            self = .http
        case RequestScheme.https.rawValue:
            self = .https
        case RequestScheme.auto.rawValue:
            self = .auto
        default:
            throw ContainerizationError(.invalidArgument, message: "unsupported scheme \(rawValue)")
        }
    }

    /// Returns the prescribed protocol to use while making a HTTP request to a webserver
    /// - Parameter host: The domain or IP address of the webserver
    /// - Returns: RequestScheme
    public func schemeFor(host: String) throws -> Self {
        guard host.count > 0 else {
            throw ContainerizationError(.invalidArgument, message: "host cannot be empty")
        }
        switch self {
        case .http, .https:
            return self
        case .auto:
            return Self.isInternalHost(host: host, dnsDomain: DefaultsStore.getOptional(key: .defaultDNSDomain)) ? .http : .https
        }
    }

    /// Checks if the given `host` string is a private IP address
    /// or a domain typically reachable only on the local system.
    internal static func isInternalHost(host: String, dnsDomain: String? = nil) -> Bool {
        // The localhost hostname is private.
        if host == "localhost" {
            return true
        }

        // If hostname uses the provided DNS domain, treat it as private.
        if let dnsDomain {
            if host.hasSuffix(".\(dnsDomain)") {
                return true
            }
        }

        // If it's any other hostname and not an IP address, it's not private access.
        guard let ipv4Address = try? IPv4Address(host) else {
            return false
        }

        let ipv4Value = ipv4Address.value

        // 10.0.0.0/8 and 127.0.0.0/8 are private CIDRs.
        if (ipv4Value & 0xff00_0000 == 0x0a00_0000) || (ipv4Value & 0xff00_0000 == 0x7f00_0000) {
            return true
        }

        // 192.168.0.0/16 is a private CIDR.
        if ipv4Value & 0xffff_0000 == 0xc0a8_0000 {
            return true
        }

        // 172.16.0.0/12 is a private CIDR.
        if ipv4Value & 0xfff0_0000 == 0xac10_0000 {
            return true
        }

        return false
    }
}
