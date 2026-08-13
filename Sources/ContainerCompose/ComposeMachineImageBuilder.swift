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

import ContainerAPIClient
import ContainerPersistence
import ContainerVersion
import ContainerizationError
import Darwin
import Dispatch
import Foundation
import Logging
import SystemPackage

/// Builds the bundled Compose machine image through the host `container` CLI.
struct ComposeMachineImageBuilder: Sendable {
    static let defaultImage = ComposeConfiguration.defaultImage

    private let commandRunner: CommandRunner
    private let resources: ComposeMachineImageResources
    private let executable: URL

    init(
        resources: ComposeMachineImageResources,
        executable: URL,
        commandRunner: CommandRunner = CommandRunner()
    ) {
        self.commandRunner = commandRunner
        self.resources = resources
        self.executable = executable
    }

    func build(image: String = defaultImage, log: Logger) async throws {
        log.info(
            "Building the default Compose machine image",
            metadata: [
                "image": "\(image)",
                "containerfile": "\(resources.containerfile.path)",
            ]
        )
        try await commandRunner.run(
            executable: executable,
            arguments: [
                "build",
                "--progress", "plain",
                "--file", resources.containerfile.path,
                "--tag", image,
                resources.directory.path,
            ],
            log: log
        )
    }

    struct CommandRunner: Sendable {
        private let implementation: @Sendable (URL, [String]) async throws -> Void

        init() {
            self.implementation = Self.runProcess
        }

        init(implementation: @escaping @Sendable (URL, [String]) async throws -> Void) {
            self.implementation = implementation
        }

        func run(executable: URL, arguments: [String], log: Logger) async throws {
            try await implementation(executable, arguments)
        }

        private static func runProcess(executable: URL, arguments: [String]) async throws {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.standardError
            process.standardError = FileHandle.standardError

            do {
                try process.run()
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to launch host container build",
                    cause: error
                )
            }

            await withTaskCancellationHandler {
                await wait(for: process)
            } onCancel: {
                terminate(process)
            }
            try Task.checkCancellation()

            guard process.terminationStatus == 0 else {
                throw ContainerizationError(
                    .internalError,
                    message: "host container build failed with status \(process.terminationStatus)"
                )
            }
        }

        private static func wait(for process: Process) async {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    continuation.resume()
                }
            }
        }

        private static func terminate(_ process: Process) {
            let processID = process.processIdentifier
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    _ = Darwin.kill(processID, SIGKILL)
                }
            }
        }
    }

    static func make(
        health: SystemHealth,
        executablePath: FilePath = CommandLine.executablePath,
        mainResourceURL: URL? = Bundle.main.resourceURL,
        moduleResourceURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> ComposeMachineImageBuilder {
        let resources = try ComposeMachineImageResources.locate(
            executablePath: executablePath,
            mainResourceURL: mainResourceURL,
            moduleResourceURL: moduleResourceURL,
            fileManager: fileManager
        )
        let installedExecutable = health.installRoot
            .appendingPathComponent("bin")
            .appendingPathComponent("container")
        let developmentExecutable = URL(fileURLWithPath: executablePath.string)
            .deletingLastPathComponent()
            .appendingPathComponent("container")
        let executable = [installedExecutable, developmentExecutable]
            .first { fileManager.isExecutableFile(atPath: $0.path) }
        guard let executable else {
            throw ContainerizationError(
                .notFound,
                message: "host container executable is unavailable; searched: \(installedExecutable.path), \(developmentExecutable.path)"
            )
        }

        return ComposeMachineImageBuilder(
            resources: resources,
            executable: executable
        )
    }
}
