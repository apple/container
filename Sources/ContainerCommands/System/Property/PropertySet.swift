//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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
import ContainerizationExtras
import ContainerizationOCI
import Foundation

extension Application {
    public struct PropertySet: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set a property value"
        )

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "The property ID")
        var id: String

        @Argument(help: "The property value")
        var value: String

        public init() {}

        public func run() async throws {
            guard let key = DefaultsStore.Keys(rawValue: id) else {
                throw ContainerizationError(.invalidArgument, message: "invalid property ID: \(id)")
            }

            switch key {
            case .buildRosetta:
                guard let boolValue = Parser.parseBool(string: value) else {
                    throw ContainerizationError(.invalidArgument, message: "invalid boolean value: \(value)")
                }
                DefaultsStore.setBool(value: boolValue, key: key)
            case .defaultDNSDomain, .defaultRegistryDomain:
                guard Parser.isValidDomainName(value) else {
                    throw ContainerizationError(.invalidArgument, message: "invalid domain name: \(value)")
                }
                DefaultsStore.set(value: value, key: key)
            case .defaultBuilderImage, .defaultInitImage:
                guard (try? Reference.parse(value)) != nil else {
                    throw ContainerizationError(.invalidArgument, message: "invalid image reference: \(value)")
                }
                DefaultsStore.set(value: value, key: key)
            case .defaultKernelBinaryPath:
                DefaultsStore.set(value: value, key: key)
            case .defaultKernelURL:
                guard URL(string: value) != nil else {
                    throw ContainerizationError(.invalidArgument, message: "invalid URL: \(value)")
                }
                DefaultsStore.set(value: value, key: key)
                return
            case .defaultSubnet:
                guard (try? CIDRAddress(value)) != nil else {
                    throw ContainerizationError(.invalidArgument, message: "invalid CIDRv4 address: \(value)")
                }
                DefaultsStore.set(value: value, key: key)
            }
        }
    }
}
