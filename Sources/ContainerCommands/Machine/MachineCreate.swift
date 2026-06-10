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
import ContainerizationError
import ContainerizationOCI
import Foundation
import MachineAPIClient
import TerminalProgress

extension Application {
    public struct MachineCreate: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new container machine and boot it")

        @OptionGroup(title: "Management options")
        var managementFlags: Flags.MachineManagement

        @OptionGroup(title: "Registry options")
        var registryFlags: Flags.Registry

        @OptionGroup(title: "Progress options")
        var progressFlags: Flags.Progress

        @OptionGroup(title: "Image fetch options")
        var imageFetchFlags: Flags.ImageFetch

        @OptionGroup
        public var logOptions: Flags.Logging

        @Option(name: [.short, .long], help: "Name for the container machine")
        public var name: String?

        @Flag(name: .long, help: "Set this container machine as the default")
        public var setDefault: Bool = false

        @Flag(name: .long, help: "Create the container machine without booting it")
        public var noBoot: Bool = false

        @Option(name: .long, help: "Number of virtual CPUs")
        public var cpus: Int?

        @Option(name: .long, help: "Memory allocation (e.g., 2G, 8G). Default: half of system memory")
        public var memory: String?

        @Option(name: .long, help: "User's home directory mount option (ro, rw, none). Default: rw")
        public var homeMount: String?

        @Argument(help: "Container image reference (e.g., alpine:3.22)")
        var image: String

        public func run() async throws {
            let progressConfig = try self.progressFlags.makeConfig(
                showTasks: true,
                showItems: true,
                ignoreSmallSize: true,
                totalTasks: 3
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            let containerSystemConfig: ContainerSystemConfig = try await ConfigurationLoader.load()
            let defaultConfig = containerSystemConfig.machine

            let bootConfig = try defaultConfig.with(
                [
                    "cpus": cpus.map { "\($0)" },
                    "memory": memory,
                    "home-mount": homeMount,
                ].compactMapValues { $0 }
            )

            let id: String
            if let name {
                id = name
            } else {
                let reference = try Reference.parse(image)
                reference.normalize()
                let imageName = reference.name.components(separatedBy: "/").last!
                let suffix = reference.tag ?? reference.digest ?? "latest"
                id = "\(imageName)-\(suffix)"
            }

            try Utility.validEntityName(id)

            let client = MachineClient()
            let (config, resources) = try await MachineClient.machineConfigFromFlags(
                id: id,
                image: image,
                management: managementFlags,
                registry: registryFlags,
                imageFetch: imageFetchFlags,
                containerSystemConfig: containerSystemConfig,
                progressUpdate: progress.handler
            )

            do {
                try await client.create(configuration: config, resources: resources, bootConfig: bootConfig)
                progress.finish()  // Finish before subsequent output to avoid mangling
            } catch let error as ContainerizationError {
                if let cause = error.cause as? ContainerizationError, cause.isCode(.exists) {
                    let append = name == nil ? " (missing '-n/--name' flag)" : ""
                    throw ContainerizationError(.exists, message: cause.message + append)
                }
                throw error
            }

            if setDefault {
                try await client.setDefault(id: id)
            }

            if !noBoot {
                try await bootMachine(id: id, client: client, log: log, interactive: false)
            }

            print(id)
        }
    }
}
