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
import ContainerizationExtras
import Foundation

extension Application {
    public struct DNSCreate: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a local DNS domain for containers (must run as an administrator)"
        )

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "The local domain name")
        var domainName: String

        public init() {}

        public func run() async throws {
            let resolver: HostDNSResolver = HostDNSResolver()
            do {
                try resolver.createDomain(name: domainName)
                print(domainName)
            } catch let error as ContainerizationError {
                throw error
            } catch {
                throw ContainerizationError(.invalidState, message: "cannot create domain (try sudo?)")
            }

            do {
                try HostDNSResolver.reinitialize()
            } catch {
                throw ContainerizationError(.invalidState, message: "mDNSResponder restart failed, run `sudo killall -HUP mDNSResponder` to deactivate domain")
            }
        }
    }
}
