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
import ContainerizationError
import Foundation

extension Application {
    public struct DNSDelete: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a local DNS domain (must run as an administrator)",
            aliases: ["rm"]
        )

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "The local domain name")
        var domainName: String

        public init() {}

        public func run() async throws {
            let resolver = HostDNSResolver()
            do {
                try resolver.deleteDomain(name: domainName)
                print(domainName)
            } catch {
                throw ContainerizationError(.invalidState, message: "cannot delete domain (try sudo?)")
            }

            do {
                try HostDNSResolver.reinitialize()
            } catch {
                throw ContainerizationError(.invalidState, message: "mDNSResponder restart failed, run `sudo killall -HUP mDNSResponder` to deactivate domain")
            }
        }
    }
}
