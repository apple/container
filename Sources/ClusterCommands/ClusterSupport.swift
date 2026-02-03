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
import ContainerizationError
import Foundation
import Logging

enum ClusterDefaults {
    static let clusterName = "kubernetes"
    static let image = "docker.io/kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a"
    static let memory = "16G"
    static let cpus: Int64 = 6
    static let podCIDR = "10.244.0.0/16"
    static let apiPort: UInt16 = 6443
}

struct ClusterSpec: Sendable {
    let name: String
    let image: String
    let cpus: Int64
    let memory: String
    let podCIDR: String
    let apiPort: UInt16
    let kernelPath: String?
    let kubeconfigPath: URL

    var nodeName: String { "\(name)-control-plane" }

    init(
        name: String,
        image: String,
        cpus: Int64,
        memory: String,
        podCIDR: String,
        apiPort: UInt16,
        kernelPath: String?,
        kubeconfigPath: String?
    ) throws {
        self.name = name
        self.image = image
        self.cpus = cpus
        self.memory = memory
        self.podCIDR = podCIDR
        self.apiPort = apiPort
        self.kernelPath = kernelPath
        self.kubeconfigPath = KubeconfigManager.resolvePath(
            path: kubeconfigPath,
            clusterName: name
        )
    }
}

enum KubeconfigManager {
    static func resolvePath(path: String?, clusterName: String) -> URL {
        if let path {
            return expandTilde(path)
        }
        let kubeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kube")
            .appendingPathComponent("cluster", isDirectory: true)
        return kubeDir.appendingPathComponent("\(clusterName).config")
    }

    static func patch(raw: String, clusterName: String, apiPort: UInt16) -> String {
        var output = raw
        output = output.replacingOccurrences(
            of: #"server: https://.*:6443"#,
            with: "server: https://127.0.0.1:\(apiPort)",
            options: .regularExpression
        )
        output = output.replacingOccurrences(of: "name: kubernetes-admin@kubernetes", with: "name: \(clusterName)")
        output = output.replacingOccurrences(of: "name: kubernetes-admin", with: "name: admin")
        output = output.replacingOccurrences(of: "name: kubernetes", with: "name: \(clusterName)")
        output = output.replacingOccurrences(of: "cluster: kubernetes", with: "cluster: \(clusterName)")
        output = output.replacingOccurrences(of: "user: kubernetes-admin", with: "user: admin")
        output = output.replacingOccurrences(
            of: #"current-context:.*"#,
            with: "current-context: \(clusterName)",
            options: .regularExpression
        )
        return output
    }

    static func write(config: String, to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        let data = Data(config.utf8)
        try data.write(to: path, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path.path
        )
    }

    static func read(at path: URL) throws -> String {
        let data = try Data(contentsOf: path)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ContainerizationError(.invalidArgument, message: "kubeconfig at \(path.path) is not valid utf8")
        }
        return content
    }
}

struct ExecResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum ClusterExecutor {
    static func run(
        container: ClientContainer,
        command: [String],
        log: Logger,
        captureOutput: Bool,
        allowFailure: Bool = false
    ) async throws -> ExecResult {
        guard let executable = command.first else {
            throw ContainerizationError(.invalidArgument, message: "command is empty")
        }

        var config = container.configuration.initProcess
        config.executable = executable
        config.arguments = Array(command.dropFirst())
        config.terminal = false

        if captureOutput {
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let process = try await container.createProcess(
                id: UUID().uuidString.lowercased(),
                configuration: config,
                stdio: [
                    nil,
                    stdoutPipe.fileHandleForWriting,
                    stderrPipe.fileHandleForWriting,
                ]
            )
            try await process.start()
            let exitCode = try await process.wait()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            if exitCode != 0 && !allowFailure {
                throw ContainerizationError(
                    .internalError,
                    message: "command failed with exit code \(exitCode): \(command.joined(separator: " "))\n\(stderr)"
                )
            }
            return ExecResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
        }

        let io = try ProcessIO.create(tty: false, interactive: false, detach: false)
        defer { try? io.close() }
        let process = try await container.createProcess(
            id: UUID().uuidString.lowercased(),
            configuration: config,
            stdio: io.stdio
        )
        let exitCode = try await io.handleProcess(process: process, log: log)
        if exitCode != 0 && !allowFailure {
            throw ContainerizationError(
                .internalError,
                message: "command failed with exit code \(exitCode): \(command.joined(separator: " "))"
            )
        }
        return ExecResult(stdout: "", stderr: "", exitCode: exitCode)
    }
}

enum ClusterContainer {
    static func ensureRunning(_ container: ClientContainer) throws {
        if container.status != .running {
            throw ContainerizationError(.invalidState, message: "container \(container.id) is not running")
        }
    }

    static func bootstrapAndStart(container: ClientContainer) async throws {
        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }
        let process = try await container.bootstrap(stdio: io.stdio)
        try await process.start()
        try io.closeAfterStart()
    }
}

private func expandTilde(_ path: String) -> URL {
    if path.hasPrefix("~") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = path.replacingOccurrences(of: "~", with: home)
        return URL(fileURLWithPath: expanded)
    }
    return URL(fileURLWithPath: path)
}
