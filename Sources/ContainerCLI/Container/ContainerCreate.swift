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
import ContainerizationError
import Foundation
import TerminalProgress

extension Application {
    struct ContainerCreate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new container")

        @Argument(help: "Image name")
        var image: String

        @Argument(help: "Container init process arguments")
        var arguments: [String] = []

        @OptionGroup
        var processFlags: Flags.Process

        @OptionGroup
        var resourceFlags: Flags.Resource

        @OptionGroup
        var managementFlags: Flags.Management

        @OptionGroup
        var registryFlags: Flags.Registry

        @OptionGroup
        var global: Flags.Global

        func run() async throws {
            let progressConfig = try ProgressConfig(
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

            let id = Utility.createContainerID(name: self.managementFlags.name)
            try Utility.validEntityName(id)

            let ck = try await Utility.containerConfigFromFlags(
                id: id,
                image: image,
                arguments: arguments,
                process: processFlags,
                management: managementFlags,
                resource: resourceFlags,
                registry: registryFlags,
                progressUpdate: progress.handler
            )

            let options = ContainerCreateOptions(autoRemove: managementFlags.remove)
            let container = try await ClientContainer.create(configuration: ck.0, options: options, kernel: ck.1)

            if !self.managementFlags.cidfile.isEmpty {
                let path = self.managementFlags.cidfile
                let data = container.id.data(using: .utf8)
                var attributes = [FileAttributeKey: Any]()
                attributes[.posixPermissions] = 0o644
                let success = FileManager.default.createFile(
                    atPath: path,
                    contents: data,
                    attributes: attributes
                )
                guard success else {
                    throw ContainerizationError(
                        .internalError, message: "failed to create cidfile at \(path): \(errno)")
                }
            }
            progress.finish()

            print(container.id)
        }
    }
}
