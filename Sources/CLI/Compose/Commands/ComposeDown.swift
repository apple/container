//
//  ComposeDown.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/19/25.
//

import ContainerClient
import Foundation
import ArgumentParser
import Yams

struct ComposeDown: AsyncParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "down",
        abstract: "Stop containers with container-compose"
    )

    @OptionGroup
    var process: Flags.Process

    private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    var dockerComposePath: String { "\(cwd)/docker-compose.yml" }  // Path to docker-compose.yml

    private var fileManager: FileManager { FileManager.default }
    private var projectName: String?
    
    mutating func run() async throws {
        // Read docker-compose.yml content
        guard let yamlData = fileManager.contents(atPath: dockerComposePath) else {
            throw YamlError.dockerfileNotFound(dockerComposePath)
        }
        
        // Decode the YAML file into the DockerCompose struct
        let dockerComposeString = String(data: yamlData, encoding: .utf8)!
        let dockerCompose = try YAMLDecoder().decode(DockerCompose.self, from: dockerComposeString)
        
        // Determine project name for container naming
        if let name = dockerCompose.name {
            projectName = name
            print("Info: Docker Compose project name parsed as: \(name)")
            print("Note: The 'name' field currently only affects container naming (e.g., '\(name)-serviceName'). Full project-level isolation for other resources (networks, implicit volumes) is not implemented by this tool.")
        } else {
            projectName = URL(fileURLWithPath: cwd).lastPathComponent // Default to directory name
            print("Info: No 'name' field found in docker-compose.yml. Using directory name as project name: \(projectName)")
        }
        
        try await stopOldStuff(remove: false)
    }
    
    /// Returns the names of all containers whose names start with a given prefix.
    /// - Parameter prefix: The container name prefix (e.g. `"Assignment"`).
    /// - Returns: An array of matching container names.
    func getContainersWithPrefix(_ prefix: String) async throws -> [String] {
        let result = try await runCommand("container", args: ["list", "-a"])
        let lines = result.stdout.split(separator: "\n")

        return lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let components = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let name = components.first else { return nil }
            return name.hasPrefix(prefix) ? String(name) : nil
        }
    }
    
    func stopOldStuff(remove: Bool) async throws {
        guard let projectName else { return }
        let containers = try await getContainersWithPrefix(projectName)
        
        for container in containers {
            print("Stopping container: \(container)")
            do {
                try await runCommand("container", args: ["stop", container])
                if remove {
                    try await runCommand("container", args: ["rm", container])
                }
            } catch {
            }
        }
    }
    
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
        return try await withCheckedThrowingContinuation { continuation in
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
}
