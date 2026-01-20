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

import AsyncHTTPClient
import ContainerResource
import Containerization
import ContainerizationOS
import Foundation
import Testing

class CLITest {
    struct Image: Codable {
        let reference: String
    }

    // These structs need to track their counterpart presentation structs in CLI.
    struct ImageInspectOutput: Codable {
        let name: String
        let variants: [variant]
        struct variant: Codable {
            let platform: imagePlatform
            struct imagePlatform: Codable {
                let os: String
                let architecture: String
            }
        }
    }

    struct NetworkInspectOutput: Codable {
        let id: String
        let state: String
        let config: NetworkConfiguration
        let status: NetworkStatus?
    }

    init() throws {}

    let testUUID = UUID().uuidString

    var testDir: URL! {
        let tempDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".clitests")
            .appendingPathComponent(testUUID)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    let alpine = "ghcr.io/linuxcontainers/alpine:3.20"
    let alpine318 = "ghcr.io/linuxcontainers/alpine:3.18"
    let busybox = "ghcr.io/containerd/busybox:1.36"

    let defaultContainerArgs = ["sleep", "infinity"]

    var executablePath: URL {
        get throws {
            let containerPath = ProcessInfo.processInfo.environment["CONTAINER_CLI_PATH"]
            if let containerPath {
                return URL(filePath: containerPath)
            }
            let fileManager = FileManager.default
            let currentDir = fileManager.currentDirectoryPath

            let releaseURL = URL(fileURLWithPath: currentDir)
                .appendingPathComponent(".build")
                .appendingPathComponent("release")
                .appendingPathComponent("container")

            let debugURL = URL(fileURLWithPath: currentDir)
                .appendingPathComponent(".build")
                .appendingPathComponent("debug")
                .appendingPathComponent("container")

            let releaseExists = fileManager.fileExists(atPath: releaseURL.path)
            let debugExists = fileManager.fileExists(atPath: debugURL.path)

            if releaseExists && debugExists {  // choose the latest build
                do {
                    let releaseAttributes = try fileManager.attributesOfItem(atPath: releaseURL.path)
                    let debugAttributes = try fileManager.attributesOfItem(atPath: debugURL.path)

                    if let releaseDate = releaseAttributes[.modificationDate] as? Date,
                        let debugDate = debugAttributes[.modificationDate] as? Date
                    {
                        return (releaseDate > debugDate) ? releaseURL : debugURL
                    }
                } catch {
                    throw CLIError.binaryAttributesNotFound(error)
                }
            } else if releaseExists {
                return releaseURL
            } else if debugExists {
                return debugURL
            }
            // both do not exist
            throw CLIError.binaryNotFound
        }
    }

    func run(arguments: [String], stdin: Data? = nil, currentDirectory: URL? = nil) throws -> (outputData: Data, output: String, error: String, status: Int32) {
        let process = Process()
        process.executableURL = try executablePath
        process.arguments = arguments
        if let directory = currentDirectory {
            process.currentDirectoryURL = directory
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputData: Data
        let errorData: Data
        do {
            try process.run()
            if let data = stdin {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.closeFile()
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            throw CLIError.executionFailed("Failed to run CLI: \(error)")
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        return (outputData: outputData, output: output, error: error, status: process.terminationStatus)
    }

    func runInteractive(arguments: [String], currentDirectory: URL? = nil) throws -> Terminal {
        let process = Process()
        process.executableURL = try executablePath
        process.arguments = arguments
        if let directory = currentDirectory {
            process.currentDirectoryURL = directory
        }

        do {
            let (parent, child) = try Terminal.create()
            process.standardInput = child.handle
            process.standardOutput = child.handle
            process.standardError = child.handle

            try process.run()
            return parent
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    func waitForContainerRunning(_ name: String, _ totalAttempts: Int64 = 100) throws {
        var attempt = 0
        var found = false
        while attempt < totalAttempts && !found {
            attempt += 1
            let status = try? getContainerStatus(name)
            if status == "running" {
                found = true
                continue
            }
            sleep(1)
        }
        if !found {
            throw CLIError.containerNotFound(name)
        }
    }

    enum CLIError: Error {
        case executionFailed(String)
        case invalidInput(String)
        case invalidOutput(String)
        case containerNotFound(String)
        case containerRunFailed(String)
        case binaryNotFound
        case binaryAttributesNotFound(Error)
    }

    func doLongRun(
        name: String,
        image: String? = nil,
        args: [String]? = nil,
        containerArgs: [String]? = nil,
        autoRemove: Bool = true
    ) throws {
        var runArgs = [
            "run"
        ]
        if autoRemove {
            runArgs.append("--rm")
        }
        runArgs.append(contentsOf: [
            "--name",
            name,
            "-d",
        ])
        if let args {
            runArgs.append(contentsOf: args)
        }

        if let image {
            runArgs.append(image)
        } else {
            runArgs.append(alpine)
        }

        if let containerArgs {
            runArgs.append(contentsOf: containerArgs)
        } else {
            runArgs.append(contentsOf: defaultContainerArgs)
        }

        let (_, _, error, status) = try run(arguments: runArgs)
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    func doExec(name: String, cmd: [String], detach: Bool = false) throws -> String {
        var execArgs = [
            "exec"
        ]
        if detach {
            execArgs.append("-d")
        }
        execArgs.append(name)
        execArgs.append(contentsOf: cmd)
        let (_, resp, error, status) = try run(arguments: execArgs)
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
        return resp
    }

    func doStop(name: String, signal: String = "SIGKILL") throws {
        let (_, _, error, status) = try run(arguments: [
            "stop",
            "-s",
            signal,
            name,
        ])
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    func doCreate(
        name: String,
        image: String? = nil,
        args: [String]? = nil,
        volumes: [String] = [],
        networks: [String] = []
    ) throws {
        let image = image ?? alpine
        let args: [String] = args ?? ["sleep", "infinity"]

        var arguments = ["create", "--rm", "--name", name]

        // Add volume mounts
        for volume in volumes {
            arguments += ["-v", volume]
        }

        // Add networks (can include properties like "network,mac=XX:XX:XX:XX:XX:XX")
        for network in networks {
            arguments += ["--network", network]
        }

        arguments += [image] + args

        let (_, _, error, status) = try run(arguments: arguments)
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    func doStart(name: String) throws {
        let (_, _, error, status) = try run(arguments: [
            "start",
            name,
        ])
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    struct inspectOutput: Codable {
        let status: String
        let configuration: ContainerConfiguration
        let networks: [ContainerResource.Attachment]
    }

    func getContainerStatus(_ name: String) throws -> String {
        try inspectContainer(name).status
    }

    func inspectContainer(_ name: String) throws -> inspectOutput {
        let response = try run(arguments: [
            "inspect",
            name,
        ])
        let cmdStatus = response.status
        guard cmdStatus == 0 else {
            throw CLIError.executionFailed("container inspect failed: exit \(cmdStatus)")
        }

        let output = response.output
        guard let jsonData = output.data(using: .utf8) else {
            throw CLIError.invalidOutput("container inspect output invalid")
        }

        let decoder = JSONDecoder()

        typealias inspectOutputs = [inspectOutput]

        let io = try decoder.decode(inspectOutputs.self, from: jsonData)
        guard io.count > 0 else {
            throw CLIError.containerNotFound(name)
        }
        return io[0]
    }

    func inspectImage(_ name: String) throws -> String {
        let response = try run(arguments: [
            "image",
            "inspect",
            name,
        ])
        let cmdStatus = response.status
        guard cmdStatus == 0 else {
            throw CLIError.executionFailed("image inspect failed: exit \(cmdStatus)")
        }

        let output = response.output
        guard let jsonData = output.data(using: .utf8) else {
            throw CLIError.invalidOutput("image inspect output invalid")
        }

        let decoder = JSONDecoder()

        struct inspectOutput: Codable {
            let name: String
        }

        typealias inspectOutputs = [inspectOutput]

        let io = try decoder.decode(inspectOutputs.self, from: jsonData)
        guard io.count > 0 else {
            throw CLIError.containerNotFound(name)
        }
        return io[0].name
    }

    func doPull(imageName: String, args: [String]? = nil) throws {
        var pullArgs = [
            "image",
            "pull",
        ]
        if let args {
            pullArgs.append(contentsOf: args)
        }
        pullArgs.append(imageName)

        let (_, _, error, status) = try run(arguments: pullArgs)
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    func doImageListQuite() throws -> [String] {
        let args = [
            "image",
            "list",
            "-q",
        ]

        let (_, out, error, status) = try run(arguments: args)
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
    }

    func doInspectImages(image: String) throws -> [ImageInspectOutput] {
        let (_, output, error, status) = try run(arguments: [
            "image",
            "inspect",
            image,
        ])

        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }

        guard let jsonData = output.data(using: .utf8) else {
            throw CLIError.invalidOutput("image inspect output invalid \(output)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode([ImageInspectOutput].self, from: jsonData)
    }

    func doDefaultRegistrySet(domain: String) throws {
        let args = [
            "system",
            "property",
            "set",
            "registry.domain",
            domain,
        ]
        let (_, _, error, status) = try run(arguments: args)
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    func doDefaultRegistryUnset() throws {
        let args = [
            "system",
            "property",
            "clear",
            "registry.domain",
        ]
        let (_, _, error, status) = try run(arguments: args)
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    func doRemove(name: String, force: Bool = false) throws {
        var args = ["delete"]
        if force {
            args.append("--force")
        }
        args.append(name)

        let (_, _, error, status) = try run(arguments: args)
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    func getClient() -> HTTPClient {
        var httpConfiguration = HTTPClient.Configuration()
        let proxyConfig: HTTPClient.Configuration.Proxy? = {
            let proxyEnv = ProcessInfo.processInfo.environment["HTTP_PROXY"]
            guard let proxyEnv else {
                return nil
            }
            guard let url = URL(string: proxyEnv), let host = url.host(), let port = url.port else {
                return nil
            }
            return .server(host: host, port: port)
        }()
        httpConfiguration.proxy = proxyConfig
        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: httpConfiguration)
    }

    func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        return try await body(tempDir)
    }

    func doRemoveImages(images: [String]? = nil) throws {
        var args = [
            "image",
            "rm",
        ]

        if let images {
            args.append(contentsOf: images)
        } else {
            args.append("--all")
        }

        let (_, _, error, status) = try run(arguments: args)
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    func isImagePresent(targetImage: String) throws -> Bool {
        let images = try doListImages()
        return images.contains(where: { image in
            if image.reference == targetImage {
                return true
            }
            return false
        })
    }

    func doListImages() throws -> [Image] {
        let (_, output, error, status) = try run(arguments: [
            "image",
            "list",
            "--format",
            "json",
        ])
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }

        guard let jsonData = output.data(using: .utf8) else {
            throw CLIError.invalidOutput("image list output invalid \(output)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode([Image].self, from: jsonData)
    }

    func doImageTag(image: String, newName: String) throws {
        let tagArgs = [
            "image",
            "tag",
            image,
            newName,
        ]

        let (_, _, error, status) = try run(arguments: tagArgs)
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    func doNetworkCreate(name: String) throws {
        let (_, _, error, status) = try run(arguments: ["network", "create", name])
        if status != 0 {
            throw CLIError.executionFailed("network create failed: \(error)")
        }
    }

    func doNetworkDeleteIfExists(name: String) {
        let (_, _, _, _) = (try? run(arguments: ["network", "rm", name])) ?? (nil, "", "", 1)
    }
}
