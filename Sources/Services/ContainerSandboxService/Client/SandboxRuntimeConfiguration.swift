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

import ContainerResource
import Containerization
import ContainerizationError
import Foundation

public struct RuntimeConfiguration: Codable, Sendable {
    static let runtimeConfigurationFilename = "runtime-configuration.json"

    public let path: URL
    public let initialFilesystem: Filesystem
    public let kernel: Kernel
    public let containerConfiguration: ContainerConfiguration?
    public let containerRootFilesystem: Filesystem?
    public let options: ContainerCreateOptions?

    public init(
        path: URL,
        initialFilesystem: Filesystem,
        kernel: Kernel,
        containerConfiguration: ContainerConfiguration? = nil,
        containerRootFilesystem: Filesystem? = nil,
        options: ContainerCreateOptions? = nil
    ) {
        self.path = path
        self.initialFilesystem = initialFilesystem
        self.kernel = kernel
        self.containerConfiguration = containerConfiguration
        self.containerRootFilesystem = containerRootFilesystem
        self.options = options
    }

    public var runtimeConfigurationPath: URL {
        self.path.appendingPathComponent(Self.runtimeConfigurationFilename)
    }

    public func writeRuntimeConfiguration() throws {
        // Ensure the parent directory exists
        let directory = self.runtimeConfigurationPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try JSONEncoder().encode(self)
        try data.write(to: self.runtimeConfigurationPath)
    }

    public static func readRuntimeConfiguration(from runtimeConfigurationPath: URL) throws -> RuntimeConfiguration {
        let configurationPath = runtimeConfigurationPath.appendingPathComponent(RuntimeConfiguration.runtimeConfigurationFilename)
        guard FileManager.default.fileExists(atPath: configurationPath.path) else {
            throw ContainerizationError(
                .notFound,
                message: "runtime configuration file not found at path: \(configurationPath.path)"
            )
        }

        let data = try Data(contentsOf: configurationPath)
        return try JSONDecoder().decode(RuntimeConfiguration.self, from: data)
    }
}
