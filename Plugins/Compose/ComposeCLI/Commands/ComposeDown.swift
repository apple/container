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

//
//  ComposeDown.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/19/25.
//

import ArgumentParser
import ContainerCLI
import ContainerClient
import Foundation
import Yams

public struct ComposeDown: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "down",
        abstract: "Stop containers with compose"
    )

    @Argument(help: "Specify the services to stop")
    var services: [String] = []

    @OptionGroup
    var process: Flags.Process

    private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String = "compose.yml"
    private var composePath: String { "\(cwd)/\(composeFilename)" }  // Path to compose.yml

    private var fileManager: FileManager { FileManager.default }
    private var projectName: String?

    public mutating func run() async throws {

        // Check for supported filenames and extensions
        let filenames = [
            "compose.yml",
            "compose.yaml",
            "docker-compose.yml",
            "docker-compose.yaml",
        ]
        for filename in filenames {
            if fileManager.fileExists(atPath: filename) {
                composeFilename = filename
                break
            }
        }

        // Read docker-compose.yml content
        guard let yamlData = fileManager.contents(atPath: composePath) else {
            let path = URL(fileURLWithPath: composePath)
                .deletingLastPathComponent()
                .path
            throw YamlError.composeFileNotFound(path)
        }

        // Decode the YAML file into the DockerCompose struct
        let dockerComposeString = String(data: yamlData, encoding: .utf8)!
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: dockerComposeString)

        // Determine project name for container naming
        if let name = dockerCompose.name {
            projectName = name
            print("Info: Docker Compose project name parsed as: \(name)")
            print(
                "Note: The 'name' field currently only affects container naming (e.g., '\(name)-serviceName'). Full project-level isolation for other resources (networks, implicit volumes) is not implemented by this tool."
            )
        } else {
            projectName = URL(fileURLWithPath: cwd).lastPathComponent  // Default to directory name
            print("Info: No 'name' field found in docker-compose.yml. Using directory name as project name: \(projectName ?? "")")
        }

        var services: [(serviceName: String, service: Service)] = dockerCompose.services.map({ ($0, $1) })
        services = try Service.topoSortConfiguredServices(services)

        // Filter for specified services
        if !self.services.isEmpty {
            services = services.filter({ serviceName, service in
                self.services.contains(where: { $0 == serviceName }) || self.services.contains(where: { service.dependedBy.contains($0) })
            })
        }

        try await stopOldStuff(services.map({ $0.serviceName }), remove: false)
    }

    private func stopOldStuff(_ services: [String], remove: Bool) async throws {
        guard let projectName else { return }
        let containers = services.map { "\(projectName)-\($0)" }

        for container in containers {
            print("Stopping container: \(container)")
            guard let container = try? await ClientContainer.get(id: container) else { continue }

            do {
                try await container.stop()
            } catch {
            }
            if remove {
                do {
                    try await container.delete()
                } catch {
                }
            }
        }
    }
}
