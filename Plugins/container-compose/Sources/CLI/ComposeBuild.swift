//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
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
import ComposeCore
import ContainerCommands
import Foundation

struct ComposeBuild: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build or rebuild services"
    )

    @OptionGroup
    var composeOptions: ComposeOptions

    @OptionGroup
    var global: ComposeGlobalOptions

    @Flag(name: .long, help: "Do not use cache when building the image")
    var noCache: Bool = false

    @Flag(name: .long, help: "Attempt to pull a newer version of the base images")
    var pull: Bool = false

    @Argument(help: "Services to build (omit to build all services with a build section)")
    var services: [String] = []

    func run() async throws {
        global.configureLogging()
        let fileURLs = composeOptions.getComposeFileURLs()
        composeOptions.prepareEnvironment(fileURLs: fileURLs)

        let parser = ComposeParser(log: log, allowAnchors: global.allowAnchors)
        let composeFile = try parser.parse(from: fileURLs)
        composeOptions.exportDotEnvForEnvFileExpansion(fileURLs: fileURLs)
        let projectDirectory = composeOptions.getProjectDirectory(fileURLs: fileURLs)
        let projectName = composeOptions.resolveProjectName(composeFile: composeFile, fileURLs: fileURLs)
        let project = try convertProject(
            composeFile: composeFile,
            projectName: projectName,
            projectDirectory: projectDirectory
        )

        let plan = try buildPlan(project: project, selectedServices: services)
        guard !plan.isEmpty else {
            print("No buildable services matched the provided filters. Nothing to build.")
            return
        }

        for service in plan {
            guard let build = service.build else { continue }
            var arguments = [
                "build",
                "--tag", service.image ?? "\(project.name)-\(service.name)",
            ]
            if let dockerfile = build.dockerfile, !dockerfile.isEmpty {
                arguments += ["--file", dockerfile]
            }
            if let target = build.target, !target.isEmpty {
                arguments += ["--target", target]
            }
            if noCache {
                arguments.append("--no-cache")
            }
            if pull {
                arguments.append("--pull")
            }
            arguments += (build.args ?? [:]).sorted { $0.key < $1.key }.flatMap { ["--build-arg", "\($0.key)=\($0.value)"] }
            arguments.append(build.context ?? ".")

            var command = try Application.parseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        }
    }

    internal func convertProject(
        composeFile: ComposeFile,
        projectName: String,
        projectDirectory: URL
    ) throws -> Project {
        let converter = ProjectConverter(log: log, projectDirectory: projectDirectory)
        return try converter.convert(
            composeFile: composeFile,
            projectName: projectName,
            profiles: composeOptions.profile,
            selectedServices: services
        )
    }

    internal func buildPlan(project: Project, selectedServices: [String]) throws -> [Service] {
        if selectedServices.isEmpty {
            return project.services.values
                .filter { $0.build != nil }
                .sorted { $0.name < $1.name }
        }

        var result: [Service] = []
        var missing: [String] = []
        var nonBuildable: [String] = []

        for name in selectedServices {
            guard let service = project.services[name] else {
                missing.append(name)
                continue
            }
            guard service.build != nil else {
                nonBuildable.append(name)
                continue
            }
            result.append(service)
        }

        if !missing.isEmpty {
            throw ValidationError("Services not found or not enabled by active profiles: \(missing.sorted().joined(separator: ", "))")
        }

        if !nonBuildable.isEmpty {
            throw ValidationError("Services without a build section: \(nonBuildable.sorted().joined(separator: ", "))")
        }

        return result
    }
}
