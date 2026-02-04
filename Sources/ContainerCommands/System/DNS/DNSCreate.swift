//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ArgumentParser
import ContainerAPIClient
import ContainerPersistence
import ContainerizationError
import ContainerizationExtras
import Foundation

extension Application {
    public struct DNSCreate: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a local DNS domain for containers (must run as an administrator)"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Option(name: .long, help: "Set the ip address to be redirected to localhost")
        var localhost: String?

        @Argument(help: "The local domain name")
        var domainName: String

        public init() {}

        public func run() async throws {
            var localhostIP: IPAddress? = nil
            if let localhost {
                localhostIP = try? IPAddress(localhost)
                guard let localhostIP, case .v4(_) = localhostIP else {
                    throw ContainerizationError(.invalidArgument, message: "invalid IPv4 address: \(localhost)")
                }
            }

            let resolver: HostDNSResolver = HostDNSResolver()
            do {
                try resolver.createDomain(name: domainName, localhost: localhostIP)
            } catch let error as ContainerizationError {
                throw error
            } catch {
                throw ContainerizationError(.invalidState, message: "cannot create domain (try sudo?)")
            }

            let pf = PacketFilter()
            if let from = localhostIP {
                let to = try! IPAddress("127.0.0.1")
                do {
                    try pf.createRedirectRule(from: from, to: to, domain: domainName)
                } catch {
                    _ = try resolver.deleteDomain(name: domainName)
                    throw error
                }
            }
            print(domainName)

            if localhostIP != nil {
                do {
                    try pf.reinitialize()
                } catch let error as ContainerizationError {
                    throw error
                } catch {
                    throw ContainerizationError(.invalidState, message: "failed loading pf rules")
                }
            }

            do {
                try HostDNSResolver.reinitialize()
            } catch {
                throw ContainerizationError(.invalidState, message: "mDNSResponder restart failed, run `sudo killall -HUP mDNSResponder` to deactivate domain")
            }
        }
    }
}
