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
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Foundation
import NIOCore
import NIOPosix
import TerminalProgress

extension Application {
    public struct ContainerRun: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a container")

        @OptionGroup(title: "Process options")
        var processFlags: Flags.Process

        @OptionGroup(title: "Resource options")
        var resourceFlags: Flags.Resource

        @OptionGroup(title: "Management options")
        var managementFlags: Flags.Management

        @OptionGroup(title: "Registry options")
        var registryFlags: Flags.Registry

        @OptionGroup(title: "Progress options")
        var progressFlags: Flags.Progress

        @OptionGroup(title: "Image fetch options")
        var imageFetchFlags: Flags.ImageFetch

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Image name")
        var image: String

        @Argument(parsing: .captureForPassthrough, help: "Container init process arguments")
        var arguments: [String] = []

        public func run() async throws {
            var exitCode: Int32 = 127
            let id = Utility.createContainerID(name: self.managementFlags.name)

            var progressConfig: ProgressConfig
            switch self.progressFlags.progress {
            case .none: progressConfig = try ProgressConfig(disableProgressUpdates: true)
            case .ansi:
                progressConfig = try ProgressConfig(
                    showTasks: true,
                    showItems: true,
                    ignoreSmallSize: true,
                    totalTasks: 6
                )
            }

            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            try Utility.validEntityName(id)

            // Check if container with id already exists.
            let existing = try? await ClientContainer.get(id: id)
            guard existing == nil else {
                throw ContainerizationError(
                    .exists,
                    message: "container with id \(id) already exists"
                )
            }

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

            progress.set(description: "Starting container")

            let options = ContainerCreateOptions(autoRemove: managementFlags.remove)
            let container = try await ClientContainer.create(
                configuration: ck.0,
                options: options,
                kernel: ck.1,
                initImage: ck.2
            )

            let detach = self.managementFlags.detach
            do {
                let io = try ProcessIO.create(
                    tty: self.processFlags.tty,
                    interactive: self.processFlags.interactive,
                    detach: detach
                )
                defer {
                    try? io.close()
                }

                let process = try await container.bootstrap(stdio: io.stdio)
                progress.finish()

                if !self.managementFlags.cidfile.isEmpty {
                    let path = self.managementFlags.cidfile
                    let data = id.data(using: .utf8)
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

                if detach {
                    try await process.start()
                    try io.closeAfterStart()
                    print(id)
                    return
                }

                if !self.processFlags.tty {
                    var handler = SignalThreshold(threshold: 3, signals: [SIGINT, SIGTERM])
                    handler.start {
                        print("Received 3 SIGINT/SIGTERM's, forcefully exiting.")
                        Darwin.exit(1)
                    }
                }

                exitCode = try await io.handleProcess(process: process, log: log)
            } catch {
                try? await container.delete()
                if error is ContainerizationError {
                    throw error
                }
                throw ContainerizationError(.internalError, message: "failed to run container: \(error)")
            }
            throw ArgumentParser.ExitCode(exitCode)
        }
    }
}
