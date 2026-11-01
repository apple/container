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
import ContainerizationOS
import Foundation
import SystemPackage

extension Application {
    public struct ImageImport: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "Create an image from a root filesystem tarball"
        )

        @Argument(help: "Path to the root filesystem tar archive (supports .tar and compressed .tar.gz)", completion: .file())
        var tarball: String

        @Argument(help: "The reference to assign to the imported image (format: image-name[:tag])")
        var reference: String

        @Option(help: "Set the OS for the imported image")
        var os: String = "linux"

        @Option(help: "Set the architecture for the imported image")
        var arch: String = Arch.hostArchitecture().rawValue

        @Option(
            help: "Set the platform for the imported image (format: os/arch[/variant], takes precedence over --os and --arch) [environment: CONTAINER_DEFAULT_PLATFORM]"
        )
        var platform: String?

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            let tarballPath = FilePathOps.absolutePath(FilePath(tarball))
            guard FileManager.default.fileExists(atPath: tarballPath.string) else {
                throw ContainerizationError(.notFound, message: "tarball does not exist at path \(tarballPath)")
            }

            let containerSystemConfig: ContainerSystemConfig = try await Application.loadContainerSystemConfig()
            let p = try DefaultPlatform.resolveWithDefaults(platform: platform, os: os, arch: arch, log: log)

            let image = try await ClientImage.`import`(
                from: tarballPath.string,
                reference: reference,
                platform: p,
                containerSystemConfig: containerSystemConfig
            )
            print(image.reference)
        }
    }
}
