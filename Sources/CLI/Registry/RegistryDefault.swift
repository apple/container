//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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
import ContainerClient
import ContainerPersistence
import ContainerizationError
import ContainerizationOCI
import Foundation

extension Application {
    public struct RegistryDefault: AsyncParsableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "default",
            abstract: "Manage the default image registry",
            subcommands: [
                DefaultSetCommand.self,
                DefaultUnsetCommand.self,
                DefaultInspectCommand.self,
            ]
        )
    }

    public struct DefaultSetCommand: AsyncParsableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set the default registry"
        )

        @OptionGroup
        var global: Flags.Global

        @OptionGroup
        var registry: Flags.Registry

        @Argument
        var host: String

        func run() async throws {
            let scheme = try RequestScheme(registry.scheme).schemeFor(host: host)

            let _url = "\(scheme)://\(host)"
            guard let url = URL(string: _url), let domain = url.host() else {
                throw ContainerizationError(.invalidArgument, message: "Cannot convert \(_url) to URL")
            }
            let resolvedDomain = Reference.resolveDomain(domain: domain)
            let client = RegistryClient(host: resolvedDomain, scheme: scheme.rawValue, port: url.port)
            do {
                try await client.ping()
            } catch let err as RegistryClient.Error {
                switch err {
                case .invalidStatus(url: _, .unauthorized, _), .invalidStatus(url: _, .forbidden, _):
                    break
                default:
                    throw err
                }
            }
            DefaultsStore.set(value: host, key: .defaultRegistryDomain)
            print("Set default registry to \(host)")
        }
    }

    public struct DefaultUnsetCommand: AsyncParsableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "unset",
            abstract: "Unset the default registry",
            aliases: ["clear"]
        )

        func run() async throws {
            DefaultsStore.unset(key: .defaultRegistryDomain)
            print("Unset the default registry domain")
        }
    }

    public struct DefaultInspectCommand: AsyncParsableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Display the default registry domain"
        )

        func run() async throws {
            print(DefaultsStore.get(key: .defaultRegistryDomain))
        }
    }
}
