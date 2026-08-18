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

import ArgumentParser
import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Foundation

extension Application.PodCommand {
    public struct PodCreate: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a pod for containers to be placed in"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @OptionGroup
        public var resource: Flags.Resource

        @OptionGroup
        public var dns: Flags.DNS

        @Option(name: .long, help: "Hostname the pod's machine reports, which its containers share")
        var hostname: String?

        @Option(name: .long, help: "Network to attach the pod to, which its containers share")
        var network: [String] = []

        @Flag(name: .long, help: "Let the pod's containers see each other's processes")
        var sharePidNamespace: Bool = false

        @Flag(name: .long, help: "Expose nested virtualization to the pod's containers")
        var virtualization: Bool = false

        @Flag(name: .long, help: "Enable Rosetta in the pod's containers")
        var rosetta: Bool = false

        @Option(name: .long, help: "Key=value metadata for the pod")
        var label: [String] = []

        @Argument(help: "Name for the pod")
        var name: String

        public init() {}

        public func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try await Application.loadContainerSystemConfig()

            guard ManagedContainer.nameValid(name) else {
                throw ContainerizationError(.invalidArgument, message: "pod name \(name) is not a valid name")
            }

            var configuration = PodConfiguration(id: name)
            configuration.resources = try Parser.resources(
                cpus: resource.cpus,
                memory: resource.memory,
                swap: resource.swap,
                defaultCPUs: containerSystemConfig.container.cpus,
                defaultMemory: containerSystemConfig.container.memory,
                defaultSwap: containerSystemConfig.container.swap
            )
            configuration.hostname = hostname
            configuration.shareProcessNamespace = sharePidNamespace
            configuration.virtualization = virtualization
            configuration.rosetta = rosetta
            configuration.labels = try Parser.labels(label)

            // A pod records a DNS configuration whatever it was told, since
            // what it was not told is filled from the network its machine
            // comes up on: a record naming no resolver is what asks for that.
            configuration.dns = ContainerConfiguration.DNSConfiguration(
                nameservers: dns.nameservers,
                domain: dns.domain,
                searchDomains: dns.searchDomains,
                options: dns.options
            )

            let parsedNetworks = try network.map { try Parser.network($0) }
            let networkClient = NetworkClient()
            let builtinNetworkId = try await networkClient.builtin?.id
            configuration.networks = try Utility.getAttachmentConfigurations(
                containerId: name,
                builtinNetworkId: builtinNetworkId,
                networks: parsedNetworks,
                dnsDomain: containerSystemConfig.dns.domain,
            )
            for attachmentConfiguration in configuration.networks {
                _ = try await networkClient.get(id: attachmentConfiguration.network)
            }

            let kernel = try await ClientKernel.getDefaultKernel(for: .current)
            try await ClientPod.create(configuration: configuration, kernel: kernel)
            print(name)
        }
    }
}
