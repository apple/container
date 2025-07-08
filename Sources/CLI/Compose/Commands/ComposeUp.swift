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
//  ComposeUp.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/19/25.
//

import ArgumentParser
import ContainerClient
import Foundation
@preconcurrency import Rainbow
import Yams

extension Application {
    struct ComposeUp: AsyncParsableCommand, @unchecked Sendable {
        static let configuration: CommandConfiguration = .init(
            commandName: "up",
            abstract: "Start containers with compose"
        )
        
        @Argument(help: "Specify the services to start")
        var services: [String] = []
        
        @Flag(
            name: [.customShort("d"), .customLong("detach")],
            help: "Detatches from container logs. Note: If you do NOT detatch, killing this process will NOT kill the container. To kill the container, run container-compose down")
        var detatch: Bool = false
        
        @Flag(name: [.customShort("b"), .customLong("build")])
        var rebuild: Bool = false
        
        @OptionGroup
        var process: Flags.Process
        
        private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }
        var dockerComposePath: String { "\(cwd)/docker-compose.yml" }  // Path to docker-compose.yml
        var envFilePath: String { "\(cwd)/.env" }  // Path to optional .env file
        //
        private var fileManager: FileManager { FileManager.default }
        private var projectName: String?
        private var environmentVariables: [String: String] = [:]
        private var containerIps: [String: String] = [:]
        private var containerConsoleColors: [String: NamedColor] = [:]
        
        private static let availableContainerConsoleColors: Set<NamedColor> = [
            .blue, .cyan, .magenta, .lightBlack, .lightBlue, .lightCyan, .lightYellow, .yellow, .lightGreen, .green,
        ]
        
        mutating func run() async throws {
            // Read docker-compose.yml content
            guard let yamlData = fileManager.contents(atPath: dockerComposePath) else {
                throw YamlError.dockerfileNotFound(dockerComposePath)
            }
            
            // Decode the YAML file into the DockerCompose struct
            let dockerComposeString = String(data: yamlData, encoding: .utf8)!
            let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: dockerComposeString)
            
            // Load environment variables from .env file
            environmentVariables = loadEnvFile(path: envFilePath)
            
            // Handle 'version' field
            if let version = dockerCompose.version {
                print("Info: Docker Compose file version parsed as: \(version)")
                print("Note: The 'version' field influences how a Docker Compose CLI interprets the file, but this custom 'container-compose' tool directly interprets the schema.")
            }
            
            // Determine project name for container naming
            if let name = dockerCompose.name {
                projectName = name
                print("Info: Docker Compose project name parsed as: \(name)")
                print("Note: The 'name' field currently only affects container naming (e.g., '\(name)-serviceName'). Full project-level isolation for other resources (networks, implicit volumes) is not implemented by this tool.")
            } else {
                projectName = URL(fileURLWithPath: cwd).lastPathComponent // Default to directory name
                print("Info: No 'name' field found in docker-compose.yml. Using directory name as project name: \(projectName)")
            }
            
            // Get Services to use
            var services: [(serviceName: String, service: Service)] = dockerCompose.services.map({ ($0, $1) })
            services = try Service.topoSortConfiguredServices(services)
            
            // Filter for specified services
            if !self.services.isEmpty {
                services = services.filter({ serviceName, service in
                    self.services.contains(where: { $0 == serviceName }) || self.services.contains(where: { service.dependedBy.contains($0) })
                })
            }
            
            // Stop Services
            try await stopOldStuff(services.map({ $0.serviceName }), remove: true)
            
            // Process top-level networks
            // This creates named networks defined in the docker-compose.yml
            if let networks = dockerCompose.networks {
                print("\n--- Processing Networks ---")
                for (networkName, networkConfig) in networks {
                    try await setupNetwork(name: networkName, config: networkConfig)
                }
                print("--- Networks Processed ---\n")
            }
            
            // Process top-level volumes
            // This creates named volumes defined in the docker-compose.yml
            if let volumes = dockerCompose.volumes {
                print("\n--- Processing Volumes ---")
                for (volumeName, volumeConfig) in volumes {
                    await createVolumeHardLink(name: volumeName, config: volumeConfig)
                }
                print("--- Volumes Processed ---\n")
            }
            
            // Process each service defined in the docker-compose.yml
            print("\n--- Processing Services ---")
            
            print(services.map(\.serviceName))
            for (serviceName, service) in services {
                try await configService(service, serviceName: serviceName, from: dockerCompose)
            }
            
            if !detatch {
                await waitForever()
            }
        }
        
        func waitForever() async -> Never {
            for await _ in AsyncStream<Void>(unfolding: {}) {
                // This will never run
            }
            fatalError("unreachable")
        }
        
        func getIPForRunningService(_ serviceName: String) async throws -> String? {
            guard let projectName else { return nil }
            
            let containerName = "\(projectName)-\(serviceName)"
            
            // Run the container list command
            let containers = ContainerList(all: true)
            let containerCommandOutput = try await runCommand("container", args: ["list", "-a"])
            let allLines = containerCommandOutput.stdout.components(separatedBy: .newlines)
            
            // Find the line matching the full container name
            guard let matchingLine = allLines.first(where: { $0.contains(containerName) }) else {
                return nil
            }
            
            // Extract IP using regex
            let pattern = #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
            let regex = try NSRegularExpression(pattern: pattern)
            
            let range = NSRange(matchingLine.startIndex..<matchingLine.endIndex, in: matchingLine)
            if let match = regex.firstMatch(in: matchingLine, range: range),
               let matchRange = Range(match.range, in: matchingLine)
            {
                return String(matchingLine[matchRange])
            }
            
            return nil
        }
        
        /// Repeatedly checks `container list -a` until the given container is listed as `running`.
        /// - Parameters:
        ///   - containerName: The exact name of the container (e.g. "Assignment-Manager-API-db").
        ///   - timeout: Max seconds to wait before failing.
        ///   - interval: How often to poll (in seconds).
        /// - Returns: `true` if the container reached "running" state within the timeout.
        func waitUntilServiceIsRunning(_ serviceName: String, timeout: TimeInterval = 30, interval: TimeInterval = 0.5) async throws {
            guard let projectName else { return }
            let containerName = "\(projectName)-\(serviceName)"
            
            let deadline = Date().addingTimeInterval(timeout)
            
            while Date() < deadline {
                let result = try await runCommand("container", args: ["list", "-a"])
                let lines = result.stdout
                    .split(separator: "\n")
                    .map(String.init)
                
                if lines.contains(where: { $0.contains(containerName) && $0.contains("running") }) {
                    return
                }
                
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            
            throw NSError(
                domain: "ContainerWait", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Timed out waiting for container '\(containerName)' to be running."
                ])
        }
        
        func stopOldStuff(_ services: [String], remove: Bool) async throws {
            guard let projectName else { return }
            let containers = services.map { "\(projectName)-\($0)" }
            
            for container in containers {
                print("Stopping container: \(container)")
                do {
                    try await runCommand("container", args: ["stop", container])
                } catch {
                }
                if remove {
                    do {
                        try await runCommand("container", args: ["rm", container])
                    } catch {
                    }
                }
            }
        }
        
        // MARK: Compose Top Level Functions
        
        mutating func updateEnvironmentWithServiceIP(_ serviceName: String) async throws {
            let ip = try await getIPForRunningService(serviceName)
            self.containerIps[serviceName] = ip
            for (key, value) in environmentVariables.map({ ($0, $1) }) where value == serviceName {
                self.environmentVariables[key] = ip ?? value
            }
        }
        
        func createVolumeHardLink(name volumeName: String, config volumeConfig: Volume) async {
            guard let projectName else { return }
            let actualVolumeName = volumeConfig.name ?? volumeName  // Use explicit name or key as name
            
            let volumeUrl = URL.homeDirectory.appending(path: ".containers/Volumes/\(projectName)/\(actualVolumeName)")
            let volumePath = volumeUrl.path(percentEncoded: false)
            
            print(
                "Warning: Volume source '\(actualVolumeName)' appears to be a named volume reference. The 'container' tool does not support named volume references in 'container run -v' command. Linking to \(volumePath) instead."
            )
            try? fileManager.createDirectory(atPath: volumePath, withIntermediateDirectories: true)
        }
        
        func setupNetwork(name networkName: String, config networkConfig: Network) async throws {
            let actualNetworkName = networkConfig.name ?? networkName  // Use explicit name or key as name
            
            if let externalNetwork = networkConfig.external, externalNetwork.isExternal {
                print("Info: Network '\(networkName)' is declared as external.")
                print("This tool assumes external network '\(externalNetwork.name ?? actualNetworkName)' already exists and will not attempt to create it.")
            } else {
                var networkCreateArgs: [String] = ["network", "create"]
                
                // Add driver and driver options
                if let driver = networkConfig.driver {
                    networkCreateArgs.append("--driver")
                    networkCreateArgs.append(driver)
                }
                if let driverOpts = networkConfig.driver_opts {
                    for (optKey, optValue) in driverOpts {
                        networkCreateArgs.append("--opt")
                        networkCreateArgs.append("\(optKey)=\(optValue)")
                    }
                }
                // Add various network flags
                if networkConfig.attachable == true { networkCreateArgs.append("--attachable") }
                if networkConfig.enable_ipv6 == true { networkCreateArgs.append("--ipv6") }
                if networkConfig.isInternal == true { networkCreateArgs.append("--internal") }  // CORRECTED: Use isInternal
                
                // Add labels
                if let labels = networkConfig.labels {
                    for (labelKey, labelValue) in labels {
                        networkCreateArgs.append("--label")
                        networkCreateArgs.append("\(labelKey)=\(labelValue)")
                    }
                }
                
                networkCreateArgs.append(actualNetworkName)  // Add the network name
                
                print("Creating network: \(networkName) (Actual name: \(actualNetworkName))")
                print("Executing container network create: container \(networkCreateArgs.joined(separator: " "))")
                let _ = try await runCommand("container", args: networkCreateArgs)
#warning("Network creation output not used")
                print("Network '\(networkName)' created or already exists.")
            }
        }
        
        // MARK: Compose Service Level Functions
        mutating func configService(_ service: Service, serviceName: String, from dockerCompose: DockerCompose) async throws {
            guard let projectName else { throw ComposeError.invalidProjectName }
            
            var imageToRun: String
            
            // Handle 'build' configuration
            if let buildConfig = service.build {
                imageToRun = try await buildService(buildConfig, for: service, serviceName: serviceName)
            } else if let img = service.image {
                // Use specified image if no build config
                // Pull image if necessary
                try await pullImage(img)
                imageToRun = img
            } else {
                // Should not happen due to Service init validation, but as a fallback
                throw ComposeError.imageNotFound(serviceName)
            }
            
            // Handle 'deploy' configuration (note that this tool doesn't fully support it)
            if service.deploy != nil {
                print("Note: The 'deploy' configuration for service '\(serviceName)' was parsed successfully.")
                print(
                    "However, this 'container-compose' tool does not currently support 'deploy' functionality (e.g., replicas, resources, update strategies) as it is primarily for orchestration platforms like Docker Swarm or Kubernetes, not direct 'container run' commands."
                )
                print("The service will be run as a single container based on other configurations.")
            }
            
            var runCommandArgs: [String] = []
            
            // Add detach flag if specified on the CLI
            if detatch {
                runCommandArgs.append("-d")
            }
            
            // Determine container name
            let containerName: String
            if let explicitContainerName = service.container_name {
                containerName = explicitContainerName
                print("Info: Using explicit container_name: \(containerName)")
            } else {
                // Default container name based on project and service name
                containerName = "\(projectName)-\(serviceName)"
            }
            runCommandArgs.append("--name")
            runCommandArgs.append(containerName)
            
            // REMOVED: Restart policy is not supported by `container run`
            // if let restart = service.restart {
            //     runCommandArgs.append("--restart")
            //     runCommandArgs.append(restart)
            // }
            
            // Add user
            if let user = service.user {
                runCommandArgs.append("--user")
                runCommandArgs.append(user)
            }
            
            // Add volume mounts
            if let volumes = service.volumes {
                for volume in volumes {
                    let args = try await configVolume(volume)
                    runCommandArgs.append(contentsOf: args)
                }
            }
            
            // Combine environment variables from .env files and service environment
            var combinedEnv: [String: String] = environmentVariables
            
            if let envFiles = service.env_file {
                for envFile in envFiles {
                    let additionalEnvVars = loadEnvFile(path: "\(cwd)/\(envFile)")
                    combinedEnv.merge(additionalEnvVars) { (current, _) in current }
                }
            }
            
            if let serviceEnv = service.environment {
                combinedEnv.merge(serviceEnv) { (old, new) in
                    guard !new.contains("${") else {
                        return old
                    }
                    return new
                }  // Service env overrides .env files
            }
            
            // Fill in variables
            combinedEnv = combinedEnv.mapValues({ value in
                guard value.contains("${") else { return value }
                
                let variableName = String(value.replacingOccurrences(of: "${", with: "").dropLast())
                return combinedEnv[variableName] ?? value
            })
            
            // Fill in IPs
            combinedEnv = combinedEnv.mapValues({ value in
                containerIps[value] ?? value
            })
            
            // MARK: Spinning Spot
            // Add environment variables to run command
            for (key, value) in combinedEnv {
                runCommandArgs.append("-e")
                runCommandArgs.append("\(key)=\(value)")
            }
            
            // REMOVED: Port mappings (-p) are not supported by `container run`
            // if let ports = service.ports {
            //     for port in ports {
            //         let resolvedPort = resolveVariable(port, with: envVarsFromFile)
            //         runCommandArgs.append("-p")
            //         runCommandArgs.append(resolvedPort)
            //     }
            // }
            
            // Connect to specified networks
            if let serviceNetworks = service.networks {
                for network in serviceNetworks {
                    let resolvedNetwork = resolveVariable(network, with: environmentVariables)
                    // Use the explicit network name from top-level definition if available, otherwise resolved name
                    let networkToConnect = dockerCompose.networks?[network]?.name ?? resolvedNetwork
                    runCommandArgs.append("--network")
                    runCommandArgs.append(networkToConnect)
                }
                print(
                    "Info: Service '\(serviceName)' is configured to connect to networks: \(serviceNetworks.joined(separator: ", ")) ascertained from networks attribute in docker-compose.yml."
                )
                print(
                    "Note: This tool assumes custom networks are defined at the top-level 'networks' key or are pre-existing. This tool does not create implicit networks for services if not explicitly defined at the top-level."
                )
            } else {
                print("Note: Service '\(serviceName)' is not explicitly connected to any networks. It will likely use the default bridge network.")
            }
            
            // Add hostname
            if let hostname = service.hostname {
                let resolvedHostname = resolveVariable(hostname, with: environmentVariables)
                runCommandArgs.append("--hostname")
                runCommandArgs.append(resolvedHostname)
            }
            
            // Add working directory
            if let workingDir = service.working_dir {
                let resolvedWorkingDir = resolveVariable(workingDir, with: environmentVariables)
                runCommandArgs.append("--workdir")
                runCommandArgs.append(resolvedWorkingDir)
            }
            
            // Add privileged flag
            if service.privileged == true {
                runCommandArgs.append("--privileged")
            }
            
            // Add read-only flag
            if service.read_only == true {
                runCommandArgs.append("--read-only")
            }
            
            // Handle service-level configs (note: still only parsing/logging, not attaching)
            if let serviceConfigs = service.configs {
                print(
                    "Note: Service '\(serviceName)' defines 'configs'. Docker Compose 'configs' are primarily used for Docker Swarm deployed stacks and are not directly translatable to 'container run' commands."
                )
                print("This tool will parse 'configs' definitions but will not create or attach them to containers during 'container run'.")
                for serviceConfig in serviceConfigs {
                    print(
                        "  - Config: '\(serviceConfig.source)' (Target: \(serviceConfig.target ?? "default location"), UID: \(serviceConfig.uid ?? "default"), GID: \(serviceConfig.gid ?? "default"), Mode: \(serviceConfig.mode?.description ?? "default"))"
                    )
                }
            }
            //
            // Handle service-level secrets (note: still only parsing/logging, not attaching)
            if let serviceSecrets = service.secrets {
                print(
                    "Note: Service '\(serviceName)' defines 'secrets'. Docker Compose 'secrets' are primarily used for Docker Swarm deployed stacks and are not directly translatable to 'container run' commands."
                )
                print("This tool will parse 'secrets' definitions but will not create or attach them to containers during 'container run'.")
                for serviceSecret in serviceSecrets {
                    print(
                        "  - Secret: '\(serviceSecret.source)' (Target: \(serviceSecret.target ?? "default location"), UID: \(serviceSecret.uid ?? "default"), GID: \(serviceSecret.gid ?? "default"), Mode: \(serviceSecret.mode?.description ?? "default"))"
                    )
                }
            }
            
            // Add interactive and TTY flags
            if service.stdin_open == true {
                runCommandArgs.append("-i")  // --interactive
            }
            if service.tty == true {
                runCommandArgs.append("-t")  // --tty
            }
            
            runCommandArgs.append(imageToRun)  // Add the image name as the final argument before command/entrypoint
            
            // Add entrypoint or command
            if let entrypointParts = service.entrypoint {
                runCommandArgs.append("--entrypoint")
                runCommandArgs.append(contentsOf: entrypointParts)
            } else if let commandParts = service.command {
                runCommandArgs.append(contentsOf: commandParts)
            }
            
            var serviceColor: NamedColor = Self.availableContainerConsoleColors.randomElement()!
            
            if Array(Set(containerConsoleColors.values)).sorted(by: { $0.rawValue < $1.rawValue }) != Self.availableContainerConsoleColors.sorted(by: { $0.rawValue < $1.rawValue }) {
                while containerConsoleColors.values.contains(serviceColor) {
                    serviceColor = Self.availableContainerConsoleColors.randomElement()!
                }
            }
            
            self.containerConsoleColors[serviceName] = serviceColor
            
            Task { [self, serviceColor] in
                @Sendable
                func handleOutput(_ output: String) {
                    print("\(serviceName): \(output)".applyingColor(serviceColor))
                }
                
                print("\nStarting service: \(serviceName)")
                print("Starting \(serviceName)")
                print("----------------------------------------\n")
                let _ = try await streamCommand("container", args: ["run"] + runCommandArgs, onStdout: handleOutput, onStderr: handleOutput)
            }
            
            do {
                try await waitUntilServiceIsRunning(serviceName)
                try await updateEnvironmentWithServiceIP(serviceName)
            } catch {
                print(error)
            }
        }
        
        func pullImage(_ image: String) async throws {
            let imageList = try await runCommand("container", args: ["images", "ls"]).stdout.replacingOccurrences(of: " ", with: "")
            guard !imageList.contains(image.replacingOccurrences(of: ":", with: "")) else {
                return
            }
            
            print("Pulling Image \(image)...")
            try await streamCommand("container", args: ["image", "pull", image]) { str in
                print(str.blue)
            } onStderr: { str in
                print(str.red)
            }
        }
        
        /// Builds Docker Service
        ///
        /// - Parameters:
        ///   - buildConfig: The configuration for the build
        ///   - service: The service you would like to build
        ///   - serviceName: The fallback name for the image
        ///
        /// - Returns: Image Name (`String`)
        func buildService(_ buildConfig: Build, for service: Service, serviceName: String) async throws -> String {
            
            var buildCommandArgs: [String] = ["build"]
            
            // Determine image tag for built image
            let imageToRun = service.image ?? "\(serviceName):latest"
            let searchName = imageToRun.split(separator: ":").first
            
            let imagesList = try await runCommand("container", args: ["images", "list"]).stdout
            if !rebuild, let searchName, imagesList.contains(searchName) {
                return imageToRun
            }
            
            do {
                try await runCommand("container", args: ["images", "rm", imageToRun])
            } catch {
            }
            
            buildCommandArgs.append("--tag")
            buildCommandArgs.append(imageToRun)
            
            // Resolve build context path
            let resolvedContext = resolveVariable(buildConfig.context, with: environmentVariables)
            buildCommandArgs.append(resolvedContext)
            
            // Add Dockerfile path if specified
            if let dockerfile = buildConfig.dockerfile {
                let resolvedDockerfile = resolveVariable(dockerfile, with: environmentVariables)
                buildCommandArgs.append("--file")
                buildCommandArgs.append(resolvedDockerfile)
            }
            
            // Add build arguments
            if let args = buildConfig.args {
                for (key, value) in args {
                    let resolvedValue = resolveVariable(value, with: environmentVariables)
                    buildCommandArgs.append("--build-arg")
                    buildCommandArgs.append("\(key)=\(resolvedValue)")
                }
            }
            
            print("\n----------------------------------------")
            print("Building image for service: \(serviceName) (Tag: \(imageToRun))")
            print("Executing container build: container \(buildCommandArgs.joined(separator: " "))")
            try await streamCommand("container", args: buildCommandArgs, onStdout: { print($0.blue) }, onStderr: { print($0.blue) })
            print("Image build for \(serviceName) completed.")
            print("----------------------------------------")
            
            return imageToRun
        }
        
        func configVolume(_ volume: String) async throws -> [String] {
            let resolvedVolume = resolveVariable(volume, with: environmentVariables)
            
            var runCommandArgs: [String] = []
            
            // Parse the volume string: destination[:mode]
            let components = resolvedVolume.split(separator: ":", maxSplits: 2).map(String.init)
            
            guard components.count >= 2 else {
                print("Warning: Volume entry '\(resolvedVolume)' has an invalid format (expected 'source:destination'). Skipping.")
                return []
            }
            
            let source = components[0]
            let destination = components[1]
            
            // Check if the source looks like a host path (contains '/' or starts with '.')
            // This heuristic helps distinguish bind mounts from named volume references.
            if source.contains("/") || source.starts(with: ".") || source.starts(with: "..") {
                // This is likely a bind mount (local path to container path)
                var isDirectory: ObjCBool = false
                // Ensure the path is absolute or relative to the current directory for FileManager
                let fullHostPath = (source.starts(with: "/") || source.starts(with: "~")) ? source : (cwd + "/" + source)
                
                if fileManager.fileExists(atPath: fullHostPath, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        // Host path exists and is a directory, add the volume
                        runCommandArgs.append("-v")
                        // Reconstruct the volume string without mode, ensuring it's source:destination
                        runCommandArgs.append("\(source):\(destination)")  // Use original source for command argument
                    } else {
                        // Host path exists but is a file
                        print("Warning: Volume mount source '\(source)' is a file. The 'container' tool does not support direct file mounts. Skipping this volume.")
                    }
                } else {
                    // Host path does not exist, assume it's meant to be a directory and try to create it.
                    do {
                        try fileManager.createDirectory(atPath: fullHostPath, withIntermediateDirectories: true, attributes: nil)
                        print("Info: Created missing host directory for volume: \(fullHostPath)")
                        runCommandArgs.append("-v")
                        runCommandArgs.append("\(source):\(destination)")  // Use original source for command argument
                    } catch {
                        print("Error: Could not create host directory '\(fullHostPath)' for volume '\(resolvedVolume)': \(error.localizedDescription). Skipping this volume.")
                    }
                }
            } else {
                guard let projectName else { return [] }
                let volumeUrl = URL.homeDirectory.appending(path: ".containers/Volumes/\(projectName)/\(source)")
                let volumePath = volumeUrl.path(percentEncoded: false)
                
                let destinationUrl = URL(fileURLWithPath: destination).deletingLastPathComponent()
                let destinationPath = destinationUrl.path(percentEncoded: false)
                
                print(
                    "Warning: Volume source '\(source)' appears to be a named volume reference. The 'container' tool does not support named volume references in 'container run -v' command. Linking to \(volumePath) instead."
                )
                try fileManager.createDirectory(atPath: volumePath, withIntermediateDirectories: true)
                
                // Host path exists and is a directory, add the volume
                runCommandArgs.append("-v")
                // Reconstruct the volume string without mode, ensuring it's source:destination
                runCommandArgs.append("\(volumePath):\(destinationPath)")  // Use original source for command argument
            }
            
            return runCommandArgs
        }
    }
}

// MARK: CommandLine Functions
extension Application.ComposeUp {

    /// Runs a command-line tool asynchronously and captures its output and exit code.
    ///
    /// This function uses async/await and `Process` to launch a command-line tool,
    /// returning a `CommandResult` containing the output, error, and exit code upon completion.
    ///
    /// - Parameters:
    ///   - command: The full path to the executable to run (e.g., `/bin/ls`).
    ///   - args: An array of arguments to pass to the command. Defaults to an empty array.
    /// - Returns: A `CommandResult` containing `stdout`, `stderr`, and `exitCode`.
    /// - Throws: An error if the process fails to launch.
    /// - Example:
    /// ```swift
    /// let result = try await runCommand("/bin/echo", args: ["Hello"])
    /// print(result.stdout) // "Hello\n"
    /// ```
    @discardableResult
    func runCommand(_ command: String, args: [String] = []) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Manually set PATH so it can find `container`
            process.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]) { _, new in new }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                guard stderrData.isEmpty else {
                    continuation.resume(throwing: TerminalError.commandFailed(String(decoding: stderrData, as: UTF8.self)))
                    return
                }

                let result = CommandResult(
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self),
                    exitCode: proc.terminationStatus
                )

                continuation.resume(returning: result)
            }
        }
    }

    /// Runs a command, streams stdout and stderr via closures, and completes when the process exits.
    ///
    /// - Parameters:
    ///   - command: The name of the command to run (e.g., `"container"`).
    ///   - args: Command-line arguments to pass to the command.
    ///   - onStdout: Closure called with streamed stdout data.
    ///   - onStderr: Closure called with streamed stderr data.
    /// - Returns: The process's exit code.
    /// - Throws: If the process fails to launch.
    @discardableResult
    func streamCommand(
        _ command: String,
        args: [String] = [],
        onStdout: @escaping (@Sendable (String) -> Void),
        onStderr: @escaping (@Sendable (String) -> Void)
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.environment = ProcessInfo.processInfo.environment.merging([
                "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]) { _, new in new }

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let string = String(data: data, encoding: .utf8) {
                    onStdout(string)
                }
            }

            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let string = String(data: data, encoding: .utf8) {
                    onStderr(string)
                }
            }

            process.terminationHandler = { proc in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Launches a detached command-line process without waiting for its output or termination.
    ///
    /// This function is useful when you want to spawn a process that runs in the background
    /// independently of the current ComposeUp. Output streams are redirected to null devices.
    ///
    /// - Parameters:
    ///   - command: The full path to the executable to launch (e.g., `/usr/bin/open`).
    ///   - args: An array of arguments to pass to the command. Defaults to an empty array.
    /// - Returns: The `Process` instance that was launched, in case you want to retain or manage it.
    /// - Throws: An error if the process fails to launch.
    /// - Example:
    /// ```swift
    /// try launchDetachedCommand("/usr/bin/open", args: ["/ComposeUps/Calculator.app"])
    /// ```
    @discardableResult
    func launchDetachedCommand(_ command: String, args: [String] = []) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // Manually set PATH so it can find `container`
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]) { _, new in new }

        // Set this to true to run independently of the launching app
        process.qualityOfService = .background

        try process.run()
        return process
    }
}
