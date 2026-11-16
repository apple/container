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

import ContainerResource

/// A DNS-SD service type, such as `_hap._tcp`.
public struct ServiceType: Hashable, Sendable, CustomStringConvertible {
    /// The service name label, including the leading underscore, such as `_hap`.
    public let name: String

    /// The transport that the service runs over.
    public let transport: PublishProtocol

    /// Parses a service type from its textual form.
    ///
    /// Labels after the transport, such as a domain, are ignored, so both
    /// `_hap._tcp` and `_hap._tcp.local.` are accepted. Names are not case
    /// sensitive. Subtype forms such as `_printer._sub._http._tcp` are not
    /// service types and are rejected.
    public init?(_ text: String) {
        let labels = text.lowercased().split(separator: ".", omittingEmptySubsequences: true)
        guard labels.count >= 2 else {
            return nil
        }
        let name = labels[0]
        guard name.hasPrefix("_"), (2...63).contains(name.utf8.count) else {
            return nil
        }
        // RFC 6763 section 7: "_tcp" for TCP, and "_udp" for everything else.
        switch labels[1] {
        case "_tcp": self.transport = .tcp
        case "_udp": self.transport = .udp
        default: return nil
        }
        self.name = String(name)
    }

    public var description: String {
        "\(name)._\(transport.rawValue)"
    }
}

/// A named instance of a service, such as `Homebridge 1A2B` of type `_hap._tcp`.
public struct ServiceInstance: Hashable, Sendable, CustomStringConvertible {
    /// The instance name, unescaped.
    public let name: String

    /// The type of the service.
    public let type: ServiceType

    public init(name: String, type: ServiceType) {
        self.name = name
        self.type = type
    }

    public var description: String {
        "\(name).\(type)"
    }
}

/// The location and metadata of a service instance.
public struct ResolvedService: Equatable, Sendable {
    /// The name of the host that provides the service.
    public let host: String

    /// The port that the service listens on.
    public let port: UInt16

    /// The TXT record of the service, as DNS record data.
    public let txt: [UInt8]

    public init(host: String, port: UInt16, txt: [UInt8]) {
        self.host = host
        self.port = port
        self.txt = txt
    }
}
