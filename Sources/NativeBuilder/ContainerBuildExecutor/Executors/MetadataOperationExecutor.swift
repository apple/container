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

import ContainerBuildIR
import ContainerBuildSnapshotter
import Foundation

/// Executes MetadataOperation (ENV, LABEL, USER, etc.).
public struct MetadataOperationExecutor: OperationExecutor {
    public let capabilities: ExecutorCapabilities

    public init() {
        self.capabilities = ExecutorCapabilities(
            supportedOperations: [.metadata],
            maxConcurrency: 20  // Metadata ops are lightweight
        )
    }

    public func execute(_ operation: ContainerBuildIR.Operation, context: ExecutionContext) async throws -> ExecutionResult {
        guard let metadataOp = operation as? MetadataOperation else {
            throw ExecutorError(
                type: .invalidConfiguration,
                context: ExecutorError.ErrorContext(
                    operation: operation, underlyingError: NSError(domain: "Executor", code: 1),
                    diagnostics: ExecutorError.Diagnostics(environment: [:], workingDirectory: "", recentLogs: [])))
        }

        do {
            // Stub implementation
            // In a real implementation, this would update the image configuration

            let startTime = Date()
            var environmentChanges: [String: EnvironmentValue] = [:]
            var metadataChanges: [String: String] = [:]

            // Apply metadata action
            switch metadataOp.action {
            case .setEnv(let key, let value):
                environmentChanges[key] = value
                context.updateEnvironment([key: value])
                context.updateImageConfig { $0.env.append("\(key)=\(value)") }

            // Note: There's no unsetEnv in MetadataAction
            // This would need to be handled differently in a real implementation

            case .setLabel(let key, let value):
                metadataChanges[key] = value
                context.updateImageConfig { $0.labels[key] = value }

            case .setUser(let user):
                context.setUser(user)
                let userString: String
                switch user {
                case .named(let name):
                    userString = name
                case .uid(let uid):
                    userString = String(uid)
                case .userGroup(let user, let group):
                    userString = "\(user):\(group)"
                case .uidGid(let uid, let gid):
                    userString = "\(uid):\(gid)"
                }
                context.updateImageConfig { $0.user = userString }

            case .setWorkdir(let path):
                context.setWorkingDirectory(path)
                context.updateImageConfig { $0.workingDir = path }

            case .setEntrypoint(let command):
                context.updateImageConfig { config in
                    switch command {
                    case .exec(let args):
                        config.entrypoint = args
                    case .shell(let cmd):
                        config.entrypoint = ["/bin/sh", "-c", cmd]
                    }
                }

            case .setCmd(let command):
                context.updateImageConfig { config in
                    switch command {
                    case .exec(let args):
                        config.cmd = args
                    case .shell(let cmd):
                        config.cmd = ["/bin/sh", "-c", cmd]
                    }
                }

            case .expose(let port):
                context.updateImageConfig { config in
                    config.exposedPorts.insert(port.stringValue)
                }

            case .setHealthcheck(let healthcheck):
                context.updateImageConfig { $0.healthcheck = healthcheck }

            case .setStopSignal(let signal):
                context.updateImageConfig { $0.stopSignal = signal }

            case .setShell(let shell):
                // Shell affects how commands are executed
                metadataChanges["shell"] = shell.joined(separator: " ")

            case .addVolume(let path):
                context.updateImageConfig { $0.volumes.insert(path) }

            case .setEnvBatch(let vars):
                for (key, value) in vars {
                    environmentChanges[key] = value
                    context.updateEnvironment([key: value])
                }
                context.updateImageConfig { config in
                    for (key, value) in vars {
                        config.env.append("\(key)=\(value)")
                    }
                }

            case .setLabelBatch(let labels):
                for (key, value) in labels {
                    metadataChanges[key] = value
                }
                context.updateImageConfig { config in
                    for (key, value) in labels {
                        config.labels[key] = value
                    }
                }

            case .declareArg(let name, let defaultValue):
                // ARG declarations are build-time only
                metadataChanges["arg:\(name)"] = defaultValue ?? ""

            case .addOnBuild(let instruction):
                // ONBUILD is stored as metadata
                metadataChanges["onbuild:\(UUID().uuidString)"] = instruction
            }

            // Metadata operations don't change the filesystem
            // so we reuse the parent snapshot
            let snapshot =
                try context.latestSnapshot()
                ?? ContainerBuildSnapshotter.Snapshot(
                    digest: Digest(algorithm: .sha256, bytes: Data(count: 32)),
                    size: 0
                )

            let duration = Date().timeIntervalSince(startTime)

            return ExecutionResult(
                filesystemChanges: .empty,
                environmentChanges: environmentChanges,
                metadataChanges: metadataChanges,
                snapshot: snapshot,
                duration: duration
            )
        } catch {
            throw ExecutorError(
                type: .executionFailed,
                context: ExecutorError.ErrorContext(
                    operation: operation, underlyingError: error, diagnostics: ExecutorError.Diagnostics(environment: [:], workingDirectory: "", recentLogs: [])))
        }
    }

    public func canExecute(_ operation: ContainerBuildIR.Operation) -> Bool {
        operation is MetadataOperation
    }
}
