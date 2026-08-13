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

import ContainerVersion
import ContainerizationError
import Foundation
import SystemPackage

/// Locates the resources required to build the bundled Compose machine image.
struct ComposeMachineImageResources: Sendable, Equatable {
    let directory: URL
    let containerfile: URL

    init(directory: URL, containerfile: URL) {
        self.directory = directory
        self.containerfile = containerfile
    }

    static func locate(
        executablePath: FilePath = CommandLine.executablePath,
        mainResourceURL: URL? = Bundle.main.resourceURL,
        moduleResourceURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> ComposeMachineImageResources {
        let executable = URL(fileURLWithPath: executablePath.string)
        let executableDirectory = executable.deletingLastPathComponent()
        let pluginRoot = executableDirectory.deletingLastPathComponent()
        let appBundleRoot = pluginRoot.deletingLastPathComponent()
        var candidates = [
            pluginRoot.appendingPathComponent("resources"),
            appBundleRoot.appendingPathComponent("Contents/Resources/resources"),
            mainResourceURL?.appendingPathComponent("plugins/compose/resources"),
            mainResourceURL?.appendingPathComponent("plugins/compose.app/Contents/Resources/resources"),
            mainResourceURL?.appendingPathComponent("compose/resources"),
            mainResourceURL?.appendingPathComponent("resources"),
        ].compactMap { $0 }
        if let moduleResourceURL {
            candidates.append(moduleResourceURL)
        }

        var bundleSearchRoot: URL? = executableDirectory
        for _ in 0..<6 {
            guard let currentRoot = bundleSearchRoot else { break }
            candidates.append(
                currentRoot.appendingPathComponent("container_ContainerCompose.bundle/Resources")
            )
            let parent = currentRoot.deletingLastPathComponent()
            guard parent != currentRoot else { break }
            bundleSearchRoot = parent
        }

        let requiredResources = [
            "Containerfile",
            "container-compose-idle-shutdown",
            "container-compose-idle-shutdown.service",
        ]
        for directory in candidates {
            let missing = requiredResources.filter {
                !fileManager.isReadableFile(atPath: directory.appendingPathComponent($0).path)
            }
            guard missing.isEmpty else { continue }
            return ComposeMachineImageResources(
                directory: directory,
                containerfile: directory.appendingPathComponent("Containerfile")
            )
        }

        throw ContainerizationError(
            .notFound,
            message: "bundled Compose machine resources are unavailable; searched: "
                + candidates.map(\.path).joined(separator: ", ")
                + "; required: "
                + requiredResources.joined(separator: ", ")
        )
    }
}
