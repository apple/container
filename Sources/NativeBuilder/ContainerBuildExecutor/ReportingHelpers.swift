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
import ContainerBuildReporting
import Foundation

// MARK: - Helper Extensions

extension ReportContext {
    /// Create context from a build node and stage
    public init(node: BuildNode, stage: BuildStage, operation: any ContainerBuildIR.Operation) {
        self.init(
            nodeId: node.id,
            stageId: stage.name ?? "stage-\(stage.id.uuidString.prefix(8))",
            description: Self.describeOperation(operation),
            timestamp: Date(),
            sourceMap: nil
        )
    }

    /// Generate a human-readable description for an operation
    public static func describeOperation(_ operation: any ContainerBuildIR.Operation) -> String {
        switch operation {
        case let exec as ExecOperation:
            return "RUN \(exec.command.displayString)"

        case let fs as FilesystemOperation:
            switch fs.action {
            case .copy:
                return "COPY \(Self.describeSource(fs.source)) \(fs.destination)"
            case .add:
                return "ADD \(Self.describeSource(fs.source)) \(fs.destination)"
            case .remove:
                return "REMOVE \(fs.destination)"
            case .mkdir:
                return "MKDIR \(fs.destination)"
            case .symlink:
                return "SYMLINK \(fs.destination)"
            case .hardlink:
                return "HARDLINK \(fs.destination)"
            }

        case let img as ImageOperation:
            switch img.source {
            case .registry(let ref):
                return "FROM \(ref.stringValue)"
            case .scratch:
                return "FROM scratch"
            case .ociLayout(let path, let tag):
                return "FROM oci-layout:\(path)\(tag.map { ":\($0)" } ?? "")"
            case .tarball(let path):
                return "FROM tarball:\(path)"
            }

        case let meta as MetadataOperation:
            switch meta.action {
            case .setEnv(let key, let value):
                return "ENV \(key)=\(Self.describeEnvValue(value))"
            case .setEnvBatch(let vars):
                return "ENV \(vars.map { "\($0.key)=\(Self.describeEnvValue($0.value))" }.joined(separator: " "))"
            case .setWorkdir(let path):
                return "WORKDIR \(path)"
            case .setUser(let user):
                return "USER \(Self.describeUser(user))"
            case .setEntrypoint(let cmd):
                return "ENTRYPOINT \(cmd.displayString)"
            case .setCmd(let cmd):
                return "CMD \(cmd.displayString)"
            case .setLabel(let key, let value):
                return "LABEL \(key)=\(value)"
            case .setLabelBatch(let labels):
                return "LABEL \(labels.map { "\($0.key)=\($0.value)" }.joined(separator: " "))"
            case .declareArg(let name, let defaultValue):
                return "ARG \(name)\(defaultValue.map { "=\($0)" } ?? "")"
            case .expose(let ports):
                return "EXPOSE \(ports.map{$0.stringValue}.joined(separator: " "))"
            case .setStopSignal(let signal):
                return "STOPSIGNAL \(signal)"
            case .setHealthcheck(let hc):
                guard let hc = hc else {
                    return "HEALTHCHECK NONE"
                }
                switch hc.test {
                case .none:
                    return "HEALTHCHECK NONE"
                case .command(let cmd):
                    return "HEALTHCHECK CMD \(cmd.displayString)"
                case .shell(let cmd):
                    return "HEALTHCHECK CMD-SHELL \(cmd)"
                }
            case .setShell(let shell):
                return "SHELL [\(shell.map { "\"\($0)\"" }.joined(separator: ", "))]"
            case .addVolume(let path):
                return "VOLUME \(path)"
            case .addOnBuild(let instruction):
                return "ONBUILD \(instruction)"
            }

        default:
            return "Operation \(operation.operationKind.rawValue)"
        }
    }

    private static func describeSource(_ source: FilesystemSource) -> String {
        switch source {
        case .context(let ctx):
            return "\(ctx.name):\(ctx.paths.joined(separator: " "))"
        case .stage(let ref, let paths):
            let prefix: String
            switch ref {
            case .named(let name):
                prefix = name
            case .index(let idx):
                prefix = "stage-\(idx)"
            case .previous:
                prefix = "previous"
            }
            return "\(prefix):\(paths.joined(separator: " "))"
        case .image(let ref, let paths):
            return "\(ref.stringValue):\(paths.joined(separator: " "))"
        case .url(let url):
            return url.absoluteString
        case .git(let src):
            return src.repository
        case .inline(_):
            return "<inline>"
        case .scratch:
            return "scratch"
        }
    }

    private static func describeEnvValue(_ value: EnvironmentValue) -> String {
        switch value {
        case .literal(let str):
            return str
        case .buildArg(let name):
            return "${\(name)}"
        case .expansion(let name, let defaultValue):
            guard let defaultValue = defaultValue else {
                return "${\(name)}"
            }
            return "${\(name):-\(defaultValue)}"
        }
    }

    private static func describeUser(_ user: User) -> String {
        switch user {
        case .named(let name):
            return name
        case .uid(let uid):
            return String(uid)
        case .userGroup(let user, let group):
            return "\(user):\(group)"
        case .uidGid(let uid, let gid):
            return "\(uid):\(gid)"
        }
    }
}

extension BuildEventError {
    /// Create from ExecutorError
    public init(from executorError: ExecutorError) {
        let failureType: FailureType
        switch executorError.type {
        case .executionFailed:
            failureType = .executionFailed
        case .cancelled:
            failureType = .cancelled
        case .invalidConfiguration:
            failureType = .invalidConfiguration
        case .unsupportedOperation:
            failureType = .executionFailed  // Map unsupported operations to execution failures
        }

        var diags: [String: String] = [:]
        diags["workingDirectory"] = executorError.context.diagnostics.workingDirectory
        for (key, value) in executorError.context.diagnostics.environment {
            diags["env.\(key)"] = value
        }
        if !executorError.context.diagnostics.recentLogs.isEmpty {
            diags["recentLogs"] = executorError.context.diagnostics.recentLogs.joined(separator: "\n")
        }

        self.init(
            type: failureType,
            description: executorError.context.underlyingError.localizedDescription,
            diagnostics: diags
        )
    }
}
