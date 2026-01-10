//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

extension Application {
    /// Copy files/directories between a container and the local filesystem.
    ///
    /// This command uses tar archives internally for file transfer, similar to `docker cp`.
    /// It leverages the existing `exec` infrastructure to run tar inside the container.
    public struct ContainerCopy: AsyncParsableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "cp",
            abstract: "Copy files/folders between a container and the local filesystem",
            discussion: """
                Copy files or directories between a container and the local filesystem.

                Use 'container:path' for the container path and a regular path for local filesystem.

                Examples:
                  container cp mycontainer:/app/config.json ./config.json
                  container cp ./local-file.txt mycontainer:/tmp/file.txt
                  container cp mycontainer:/var/log/ ./logs/
                """
        )

        @Flag(name: .shortAndLong, help: "Archive mode (preserve uid/gid)")
        var archive: Bool = false

        @Flag(name: [.customShort("L"), .long], help: "Follow symbolic links in source")
        var followLink: Bool = false

        @Flag(name: .shortAndLong, help: "Suppress progress output")
        var quiet: Bool = false

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "Source path (container:path or local path)")
        var source: String

        @Argument(help: "Destination path (container:path or local path)")
        var destination: String

        public func run() async throws {
            let src = CopyPath.parse(source)
            let dest = CopyPath.parse(destination)

            switch (src, dest) {
            case (.container(let id, let path), .local(let localPath)):
                try await copyFromContainer(
                    containerId: id,
                    containerPath: path,
                    localPath: localPath
                )

            case (.local(let localPath), .container(let id, let path)):
                try await copyToContainer(
                    localPath: localPath,
                    containerId: id,
                    containerPath: path
                )

            case (.container, .container):
                throw ContainerizationError(
                    .invalidArgument,
                    message: "copying between containers is not supported. Copy to local first, then to the target container."
                )

            case (.local, .local):
                throw ContainerizationError(
                    .invalidArgument,
                    message: "both paths are local. Use the system 'cp' command instead."
                )
            }
        }

        /// Copy a file or directory from a container to the local filesystem.
        private func copyFromContainer(
            containerId: String,
            containerPath: String,
            localPath: String
        ) async throws {
            let container = try await ClientContainer.get(id: containerId)
            try ensureRunning(container: container)

            // Parse source path
            let srcUrl = URL(fileURLWithPath: containerPath)
            let srcBaseName = srcUrl.lastPathComponent

            // Parse destination path and determine if rename is needed
            let destUrl = URL(fileURLWithPath: localPath)
            let destBaseName = destUrl.lastPathComponent
            let resolvedLocalPath: String
            var needsRename = false

            if localPath.hasSuffix("/") {
                // Explicit directory destination
                resolvedLocalPath = localPath
            } else {
                // Check if destination exists and is a directory
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: localPath, isDirectory: &isDir) && isDir.boolValue {
                    resolvedLocalPath = localPath
                } else {
                    // Extract to parent directory, may need to rename
                    resolvedLocalPath = destUrl.deletingLastPathComponent().path
                    if !srcBaseName.isEmpty && srcBaseName != destBaseName {
                        needsRename = true
                    }
                }
            }

            // Ensure destination directory exists
            try FileManager.default.createDirectory(
                atPath: resolvedLocalPath,
                withIntermediateDirectories: true,
                attributes: nil
            )

            // Build tar command arguments for the container
            // tar -cf - -C <parent> <basename>
            var tarArgs: [String] = []
            if followLink {
                tarArgs.append("-h")  // dereference symlinks
            }
            tarArgs.append("-cf")
            tarArgs.append("-")

            let parentPath = srcUrl.deletingLastPathComponent().path

            tarArgs.append("-C")
            tarArgs.append(parentPath.isEmpty ? "/" : parentPath)
            tarArgs.append(srcBaseName.isEmpty ? "." : srcBaseName)

            // Create process configuration for tar in container
            let config = ProcessConfiguration(
                executable: "/bin/tar",
                arguments: tarArgs,
                environment: [],
                workingDirectory: "/",
                terminal: false
            )

            // Setup pipes for streaming
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            // Create process in container with stdout capture
            let process = try await container.createProcess(
                id: UUID().uuidString.lowercased(),
                configuration: config,
                stdio: [nil, stdoutPipe.fileHandleForWriting, stderrPipe.fileHandleForWriting]
            )

            // Start container tar process
            try await process.start()

            // Close write ends in parent process
            try stdoutPipe.fileHandleForWriting.close()
            try stderrPipe.fileHandleForWriting.close()

            // Create local tar extract process
            let extractProcess = Process()
            extractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")

            var extractArgs = ["-xf", "-"]
            if archive {
                extractArgs.insert("-p", at: 0)  // preserve permissions
            }
            extractArgs.append("-C")
            extractArgs.append(resolvedLocalPath)

            extractProcess.arguments = extractArgs
            extractProcess.standardInput = stdoutPipe.fileHandleForReading

            // Capture stderr for error reporting
            let extractStderrPipe = Pipe()
            extractProcess.standardError = extractStderrPipe

            // Ensure destination directory exists for extraction
            try FileManager.default.createDirectory(
                atPath: resolvedLocalPath,
                withIntermediateDirectories: true,
                attributes: nil
            )

            try extractProcess.run()

            // Wait for container process
            let exitCode = try await process.wait()

            // Close the read end of stdout pipe to signal EOF to local tar
            // This is critical - if container tar fails, local tar would hang forever otherwise
            try? stdoutPipe.fileHandleForReading.close()

            // If container process failed, terminate local tar immediately
            // The pipe close alone may not be enough on macOS due to FD inheritance
            if exitCode != 0 && extractProcess.isRunning {
                extractProcess.terminate()
            }

            // Wait for local extract process
            extractProcess.waitUntilExit()

            // Check for errors - container errors take precedence
            if exitCode != 0 {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
                throw ContainerizationError(
                    .internalError,
                    message: "failed to copy from container: tar exited with code \(exitCode). \(stderrString)"
                )
            }

            if extractProcess.terminationStatus != 0 {
                let extractStderrData = extractStderrPipe.fileHandleForReading.readDataToEndOfFile()
                let extractStderrString = String(data: extractStderrData, encoding: .utf8) ?? ""
                throw ContainerizationError(
                    .internalError,
                    message: "failed to extract files locally: tar exited with code \(extractProcess.terminationStatus). \(extractStderrString)"
                )
            }

            // If needed, rename the extracted file to match destination name
            if needsRename {
                let extractedPath =
                    resolvedLocalPath.hasSuffix("/")
                    ? "\(resolvedLocalPath)\(srcBaseName)"
                    : "\(resolvedLocalPath)/\(srcBaseName)"

                try FileManager.default.moveItem(atPath: extractedPath, toPath: localPath)
            }

            if !quiet {
                log.info("Successfully copied \(containerId):\(containerPath) to \(localPath)")
            }
        }

        /// Copy a file or directory from the local filesystem to a container.
        private func copyToContainer(
            localPath: String,
            containerId: String,
            containerPath: String
        ) async throws {
            let container = try await ClientContainer.get(id: containerId)
            try ensureRunning(container: container)

            // Validate local path exists
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory) else {
                throw ContainerizationError(
                    .notFound,
                    message: "no such file or directory: \(localPath)"
                )
            }

            // Create local tar process
            let localTarProcess = Process()
            localTarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")

            let pathUrl = URL(fileURLWithPath: localPath)
            let parentPath = pathUrl.deletingLastPathComponent().path
            let baseName = pathUrl.lastPathComponent

            var tarArgs: [String] = []
            if followLink {
                tarArgs.append("-h")  // dereference symlinks
            }
            tarArgs.append("-cf")
            tarArgs.append("-")
            tarArgs.append("-C")
            tarArgs.append(parentPath.isEmpty ? "." : parentPath)
            tarArgs.append(baseName)

            localTarProcess.arguments = tarArgs

            // Setup pipe for tar output
            let tarOutputPipe = Pipe()
            localTarProcess.standardOutput = tarOutputPipe.fileHandleForWriting

            // Capture stderr for error reporting
            let localStderrPipe = Pipe()
            localTarProcess.standardError = localStderrPipe

            // Resolve destination path in container
            // If path ends with /, treat as directory; otherwise we may need to rename
            let destUrl = URL(fileURLWithPath: containerPath)
            let destBaseName = destUrl.lastPathComponent
            let resolvedContainerPath: String
            var needsRename = false

            if containerPath.hasSuffix("/") {
                // Explicit directory destination
                resolvedContainerPath = containerPath
            } else {
                // Extract to parent directory, then rename if needed
                resolvedContainerPath = destUrl.deletingLastPathComponent().path
                if resolvedContainerPath.isEmpty {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "invalid container path: \(containerPath)"
                    )
                }
                // Check if we need to rename (source and dest basenames differ)
                if !isDirectory.boolValue && baseName != destBaseName {
                    needsRename = true
                }
            }

            // Build tar extract command for container
            var extractArgs: [String] = ["-xf", "-"]
            if archive {
                extractArgs.insert("-p", at: 0)  // preserve permissions
            }
            extractArgs.append("-C")
            extractArgs.append(resolvedContainerPath)

            // Create process configuration for tar extract in container
            let config = ProcessConfiguration(
                executable: "/bin/tar",
                arguments: extractArgs,
                environment: [],
                workingDirectory: "/",
                terminal: false
            )

            // Create stderr pipe for container process
            let containerStderrPipe = Pipe()

            // Create process in container with stdin from local tar
            let process = try await container.createProcess(
                id: UUID().uuidString.lowercased(),
                configuration: config,
                stdio: [tarOutputPipe.fileHandleForReading, nil, containerStderrPipe.fileHandleForWriting]
            )

            // Start local tar process first
            try localTarProcess.run()

            // Start container tar extract process
            try await process.start()

            // Close pipe ends appropriately
            try tarOutputPipe.fileHandleForWriting.close()
            try containerStderrPipe.fileHandleForWriting.close()

            // Wait for local tar to finish
            localTarProcess.waitUntilExit()

            // Close read end of pipe after local tar is done
            try tarOutputPipe.fileHandleForReading.close()

            // Wait for container process
            let exitCode = try await process.wait()

            // Check for errors
            if localTarProcess.terminationStatus != 0 {
                let stderrData = localStderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
                throw ContainerizationError(
                    .internalError,
                    message: "failed to create tar archive: tar exited with code \(localTarProcess.terminationStatus). \(stderrString)"
                )
            }

            if exitCode != 0 {
                let stderrData = containerStderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
                throw ContainerizationError(
                    .internalError,
                    message: "failed to extract in container: tar exited with code \(exitCode). \(stderrString)"
                )
            }

            // If needed, rename the extracted file to match destination name
            if needsRename {
                let srcPath =
                    resolvedContainerPath.hasSuffix("/")
                    ? "\(resolvedContainerPath)\(baseName)"
                    : "\(resolvedContainerPath)/\(baseName)"
                let destPath = containerPath

                let mvConfig = ProcessConfiguration(
                    executable: "/bin/mv",
                    arguments: [srcPath, destPath],
                    environment: [],
                    workingDirectory: "/",
                    terminal: false
                )

                let mvStderrPipe = Pipe()
                let mvProcess = try await container.createProcess(
                    id: UUID().uuidString.lowercased(),
                    configuration: mvConfig,
                    stdio: [nil, nil, mvStderrPipe.fileHandleForWriting]
                )

                try await mvProcess.start()
                try mvStderrPipe.fileHandleForWriting.close()

                let mvExitCode = try await mvProcess.wait()
                if mvExitCode != 0 {
                    let stderrData = mvStderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to rename file in container: mv exited with code \(mvExitCode). \(stderrString)"
                    )
                }
            }

            if !quiet {
                log.info("Successfully copied \(localPath) to \(containerId):\(containerPath)")
            }
        }

        /// Resolve the destination path, handling cases where destination is a directory.
        private func resolveDestinationPath(_ path: String, isDirectory: Bool) -> String {
            let url = URL(fileURLWithPath: path)

            // If path ends with /, treat as directory
            if path.hasSuffix("/") {
                return url.path
            }

            // Check if destination exists and is a directory
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return url.path
                }
            }

            // Return parent directory for extraction
            return url.deletingLastPathComponent().path
        }
    }
}
