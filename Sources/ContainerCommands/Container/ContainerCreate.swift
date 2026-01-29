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
import ContainerResource
import ContainerizationError
import Foundation
import TerminalProgress

extension Application {
    public struct ContainerCreate: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new container")

        @OptionGroup(title: "Process options")
        var processFlags: Flags.Process

        @OptionGroup(title: "Resource options")
        var resourceFlags: Flags.Resource

        @OptionGroup(title: "Management options")
        var managementFlags: Flags.Management

        @OptionGroup(title: "Registry options")
        var registryFlags: Flags.Registry

        @OptionGroup(title: "Image fetch options")
        var imageFetchFlags: Flags.ImageFetch

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Image name")
        var image: String

        @Argument(parsing: .captureForPassthrough, help: "Container init process arguments")
        var arguments: [String] = []

        public func run() async throws {
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
                imageFetch: imageFetchFlags,
                progressUpdate: progress.handler
            )

            let options = ContainerCreateOptions(autoRemove: managementFlags.remove)
            let container = try await ClientContainer.create(configuration: ck.0, options: options, kernel: ck.1, initImage: ck.2)

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
