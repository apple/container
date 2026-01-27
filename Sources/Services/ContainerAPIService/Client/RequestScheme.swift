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
    package func schemeFor(host: String) throws -> Self {
        guard host.count > 0 else {
            throw ContainerizationError(.invalidArgument, message: "host cannot be empty")
        }
        switch self {
        case .http, .https:
            return self
        case .auto:
            return Self.isInternalHost(host: host) ? .http : .https
        }
    }

    /// Checks if the given `host` string is a private IP address
    /// or a domain typically reachable only on the local system.
    private static func isInternalHost(host: String) -> Bool {
        if host.hasPrefix("localhost") || host.hasPrefix("127.") {
            return true
        }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") {
            return true
        }
        let regex = "(^172\\.1[6-9]\\.)|(^172\\.2[0-9]\\.)|(^172\\.3[0-1]\\.)"
        if host.range(of: regex, options: .regularExpression) != nil {
            return true
        }
        let dnsDomain = DefaultsStore.get(key: .defaultDNSDomain)
        if host.hasSuffix(".\(dnsDomain)") {
            return true
        }
        return false
    }
}
