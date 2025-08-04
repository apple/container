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

import Foundation
import Testing

@testable import ContainerBuildIR

struct OperationTests {

    // MARK: - ExecOperation Tests

    @Test func execOperationBasic() throws {
        let operation = ExecOperation(
            command: .shell("echo 'Hello, World!'")
        )

        #expect(operation.operationKind == .exec)
        #expect(operation.command.displayString == "echo 'Hello, World!'")
        #expect(operation.environment.variables.isEmpty)
        #expect(operation.mounts.isEmpty)
        #expect(operation.workingDirectory == nil)
        #expect(operation.user == nil)
        #expect(operation.network == .default)
        #expect(!operation.security.privileged)
    }

    @Test func execOperationWithEnvironment() throws {
        let environment = Environment([
            (key: "NODE_ENV", value: .literal("production")),
            (key: "PORT", value: .buildArg("HTTP_PORT")),
            (key: "DEBUG", value: .literal("false")),
        ])

        let operation = ExecOperation(
            command: .exec(["node", "server.js"]),
            environment: environment
        )

        #expect(operation.environment.variables.count == 3)

        let effectiveEnv = operation.environment.effectiveEnvironment
        #expect(effectiveEnv["NODE_ENV"] == "production")
        #expect(effectiveEnv["DEBUG"] == "false")
        // BUILD_ARG references don't resolve without context
    }

    @Test func execOperationWithMounts() throws {
        let mounts = [
            Mount(
                type: .cache,
                target: "/var/cache/apt",
                source: .local("apt-cache"),
                options: MountOptions(sharing: .shared)
            ),
            Mount(
                type: .secret,
                target: "/run/secrets/github-token",
                source: .secret("github-token"),
                options: MountOptions(readOnly: true, mode: 0o400)
            ),
            Mount(
                type: .tmpfs,
                target: "/tmp",
                source: nil,
                options: MountOptions(size: 100 * 1024 * 1024)  // 100MB
            ),
        ]

        let operation = ExecOperation(
            command: .shell("apt-get update && apt-get install -y git"),
            mounts: mounts
        )

        #expect(operation.mounts.count == 3)

        let cacheMount = operation.mounts[0]
        #expect(cacheMount.type == .cache)
        #expect(cacheMount.target == "/var/cache/apt")
        #expect(cacheMount.options.sharing == .shared)

        let secretMount = operation.mounts[1]
        #expect(secretMount.type == .secret)
        #expect(secretMount.options.readOnly == true)
        #expect(secretMount.options.mode == 0o400)

        let tmpfsMount = operation.mounts[2]
        #expect(tmpfsMount.type == .tmpfs)
        #expect(tmpfsMount.options.size == UInt32(100 * 1024 * 1024))
    }

    @Test func execOperationWithUser() throws {
        let users = [
            User.named("appuser"),
            User.uid(1000),
            User.userGroup(user: "app", group: "app"),
            User.uidGid(uid: 1000, gid: 1000),
        ]

        for user in users {
            let operation = ExecOperation(
                command: .shell("whoami"),
                user: user
            )

            #expect(operation.user == user)
        }
    }

    @Test func execOperationWithSecurity() throws {
        let capabilities = SecurityCapabilities(
            add: ["NET_ADMIN", "SYS_TIME"],
            drop: ["ALL"]
        )

        let security = SecurityOptions(
            privileged: true,
            capabilities: capabilities,
            seccompProfile: "custom.json",
            apparmorProfile: "custom-profile",
            noNewPrivileges: false
        )

        let operation = ExecOperation(
            command: .shell("mount /dev/sda1 /mnt"),
            security: security
        )

        #expect(operation.security.privileged == true)
        #expect(operation.security.capabilities?.add.contains("NET_ADMIN") == true)
        #expect(operation.security.capabilities?.drop.contains("ALL") == true)
        #expect(operation.security.seccompProfile == "custom.json")
        #expect(operation.security.apparmorProfile == "custom-profile")
        #expect(operation.security.noNewPrivileges == false)
    }

    @Test func execOperationWithNetwork() throws {
        let networkModes: [NetworkMode] = [.default, .none, .host]

        for networkMode in networkModes {
            let operation = ExecOperation(
                command: .shell("curl https://example.com"),
                network: networkMode
            )

            #expect(operation.network == networkMode)
        }
    }

    @Test func commandTypes() throws {
        let shellCommand = Command.shell("echo 'test' && ls -la")
        let execCommand = Command.exec(["ls", "-la", "/app"])

        #expect(shellCommand.displayString == "echo 'test' && ls -la")
        #expect(execCommand.displayString == "ls -la /app")

        // Test with empty exec array
        let emptyExecCommand = Command.exec([])
        #expect(emptyExecCommand.displayString == "")

        // Test with single command
        let singleExecCommand = Command.exec(["whoami"])
        #expect(singleExecCommand.displayString == "whoami")
    }

    // MARK: - FilesystemOperation Tests

    @Test func filesystemOperationBasic() throws {
        let operation = FilesystemOperation(
            action: .copy,
            source: .context(ContextSource(paths: ["src/"])),
            destination: "/app/src/"
        )

        #expect(operation.operationKind == .filesystem)
        #expect(operation.action == .copy)
        #expect(operation.destination == "/app/src/")

        if case .context(let contextSource) = operation.source {
            #expect(contextSource.paths == ["src/"])
        } else {
            Issue.record("Expected context source")
        }
    }

    @Test func filesystemOperationFromStage() throws {
        let operation = FilesystemOperation(
            action: .copy,
            source: .stage(.named("builder"), paths: ["/app/dist"]),
            destination: "/usr/share/nginx/html/"
        )

        if case .stage(let stageRef, let paths) = operation.source {
            if case .named(let name) = stageRef {
                #expect(name == "builder")
            } else {
                Issue.record("Expected named stage reference")
            }
            #expect(paths == ["/app/dist"])
        } else {
            Issue.record("Expected stage source")
        }
    }

    @Test func filesystemOperationWithMetadata() throws {
        let expectedOwnership = Ownership(user: .numeric(id: 1000), group: .numeric(id: 1000))
        let fileMetadata = FileMetadata(
            ownership: expectedOwnership,
            permissions: .mode(0o644),
            timestamps: Timestamps(
                created: Date(),
                modified: Date()
            )
        )

        let operation = FilesystemOperation(
            action: .copy,
            source: .context(
                ContextSource(
                    paths: ["config.json"]
                )),
            destination: "/etc/app/config.json",
            fileMetadata: fileMetadata
        )

        #expect(operation.fileMetadata.ownership == expectedOwnership)

        if case .mode(let mode) = operation.fileMetadata.permissions {
            #expect(mode == 0o644)
        } else {
            Issue.record("Expected mode permissions")
        }
    }

    @Test func filesystemSourceTypes() throws {
        let contextSource = FilesystemSource.context(
            ContextSource(
                paths: ["*.txt", "docs/"]
            ))

        let stageSource = FilesystemSource.stage(.index(0), paths: ["/app/binary"])
        let imageSource = FilesystemSource.image(
            ImageReference(parsing: "alpine:latest")!,
            paths: ["/etc/ssl/certs/"]
        )
        let urlSource = FilesystemSource.url(URL(string: "https://releases.example.com/v1.0.0/app.tar.gz")!)

        // Verify each source type can be created
        let sources = [contextSource, stageSource, imageSource, urlSource]
        for source in sources {
            let operation = FilesystemOperation(
                action: .copy,
                source: source,
                destination: "/test/"
            )
            #expect(operation.source == source)
        }
    }

    // MARK: - MetadataOperation Tests

    @Test func metadataOperationEnvironment() throws {
        let setEnvOperation = MetadataOperation(
            action: .setEnv(key: "NODE_ENV", value: .literal("production"))
        )

        #expect(setEnvOperation.operationKind == .metadata)

        if case .setEnv(let key, let value) = setEnvOperation.action {
            #expect(key == "NODE_ENV")
            if case .literal(let literalValue) = value {
                #expect(literalValue == "production")
            } else {
                Issue.record("Expected literal value")
            }
        } else {
            Issue.record("Expected setEnv action")
        }
    }

    @Test func metadataOperationBatchEnvironment() throws {
        let envVars = [
            (key: "NODE_ENV", value: EnvironmentValue.literal("production")),
            (key: "PORT", value: EnvironmentValue.buildArg("HTTP_PORT")),
            (key: "DEBUG", value: EnvironmentValue.literal("false")),
        ]

        let operation = MetadataOperation(
            action: .setEnvBatch(envVars)
        )

        if case .setEnvBatch(let vars) = operation.action {
            #expect(vars.count == 3)
            #expect(vars[0].key == "NODE_ENV")
            #expect(vars[1].key == "PORT")
            #expect(vars[2].key == "DEBUG")
        } else {
            Issue.record("Expected setEnvBatch action")
        }
    }

    @Test func metadataOperationLabels() throws {
        let setLabelOperation = MetadataOperation(
            action: .setLabel(key: "version", value: "1.0.0")
        )

        if case .setLabel(let key, let value) = setLabelOperation.action {
            #expect(key == "version")
            #expect(value == "1.0.0")
        } else {
            Issue.record("Expected setLabel action")
        }

        let batchLabels = [
            "version": "1.0.0",
            "maintainer": "team@example.com",
            "description": "Sample application",
        ]

        let batchLabelOperation = MetadataOperation(
            action: .setLabelBatch(batchLabels)
        )

        if case .setLabelBatch(let labels) = batchLabelOperation.action {
            #expect(labels.count == 3)
            #expect(labels["version"] == "1.0.0")
            #expect(labels["maintainer"] == "team@example.com")
        } else {
            Issue.record("Expected setLabelBatch action")
        }
    }

    @Test func metadataOperationArguments() throws {
        let operation = MetadataOperation(
            action: .declareArg(name: "BUILD_VERSION", defaultValue: "dev")
        )

        if case .declareArg(let name, let defaultValue) = operation.action {
            #expect(name == "BUILD_VERSION")
            #expect(defaultValue == "dev")
        } else {
            Issue.record("Expected declareArg action")
        }
    }

    @Test func metadataOperationExpose() throws {
        let operation = MetadataOperation(
            action: .expose(port: PortSpec(port: 8080, protocol: .tcp))
        )

        if case .expose(let port) = operation.action {
            #expect(port.port == 8080)
            #expect(port.protocol == .tcp)
        } else {
            Issue.record("Expected expose action")
        }
    }

    @Test func metadataOperationWorkdir() throws {
        let operation = MetadataOperation(
            action: .setWorkdir(path: "/app")
        )

        if case .setWorkdir(let path) = operation.action {
            #expect(path == "/app")
        } else {
            Issue.record("Expected setWorkdir action")
        }
    }

    @Test func metadataOperationUser() throws {
        let userOperations = [
            MetadataOperation(action: .setUser(user: .named("appuser"))),
            MetadataOperation(action: .setUser(user: .uid(1000))),
            MetadataOperation(action: .setUser(user: .uidGid(uid: 1000, gid: 1000))),
        ]

        for operation in userOperations {
            if case .setUser(let user) = operation.action {
                // Just verify the user is preserved
                switch user {
                case .named(let name):
                    #expect(name == "appuser")
                case .uid(let uid):
                    #expect(uid == 1000)
                case .uidGid(let uid, let gid):
                    #expect(uid == 1000)
                    #expect(gid == 1000)
                default:
                    Issue.record("Unexpected user type")
                }
            } else {
                Issue.record("Expected setUser action")
            }
        }
    }

    @Test func metadataOperationCommands() throws {
        let entrypointOperation = MetadataOperation(
            action: .setEntrypoint(command: .exec(["/app/server"]))
        )

        let cmdOperation = MetadataOperation(
            action: .setCmd(command: .shell("./start.sh"))
        )

        if case .setEntrypoint(let command) = entrypointOperation.action {
            if case .exec(let args) = command {
                #expect(args == ["/app/server"])
            } else {
                Issue.record("Expected exec command")
            }
        } else {
            Issue.record("Expected setEntrypoint action")
        }

        if case .setCmd(let command) = cmdOperation.action {
            if case .shell(let cmd) = command {
                #expect(cmd == "./start.sh")
            } else {
                Issue.record("Expected shell command")
            }
        } else {
            Issue.record("Expected setCmd action")
        }
    }

    @Test func metadataOperationHealthcheck() throws {
        let healthcheck = Healthcheck(
            test: .command(.exec(["curl", "-f", "http://localhost:8080/health"])),
            interval: 30,
            timeout: 5,
            startPeriod: 10,
            retries: 3
        )

        let operation = MetadataOperation(
            action: .setHealthcheck(healthcheck: healthcheck)
        )

        if case .setHealthcheck(let hc) = operation.action {
            #expect(hc?.interval == 30)
            #expect(hc?.timeout == 5)
            #expect(hc?.startPeriod == 10)
            #expect(hc?.retries == 3)

            if case .command(let cmd) = hc!.test,
                case .exec(let args) = cmd
            {
                #expect(args == ["curl", "-f", "http://localhost:8080/health"])
            } else {
                Issue.record("Expected command healthcheck test")
            }
        } else {
            Issue.record("Expected setHealthcheck action")
        }
    }

    @Test func metadataOperationMiscellaneous() throws {
        let stopSignalOp = MetadataOperation(action: .setStopSignal(signal: "SIGTERM"))
        let volumeOp = MetadataOperation(action: .addVolume(path: "/data"))
        let shellOp = MetadataOperation(action: .setShell(shell: ["/bin/bash", "-c"]))
        let onBuildOp = MetadataOperation(action: .addOnBuild(instruction: "RUN npm install"))

        let operations = [stopSignalOp, volumeOp, shellOp, onBuildOp]

        for operation in operations {
            #expect(operation.operationKind == .metadata)

            switch operation.action {
            case .setStopSignal(let signal):
                #expect(signal == "SIGTERM")
            case .addVolume(let path):
                #expect(path == "/data")
            case .setShell(let shell):
                #expect(shell == ["/bin/bash", "-c"])
            case .addOnBuild(let instruction):
                #expect(instruction == "RUN npm install")
            default:
                Issue.record("Unexpected action type")
            }
        }
    }

    // MARK: - ImageOperation Tests

    @Test func imageOperationFromRegistry() throws {
        let imageRef = ImageReference(parsing: "alpine:3.18")!
        let operation = ImageOperation(
            source: .registry(imageRef),
            platform: .linuxAMD64
        )

        #expect(operation.operationKind == .image)
        #expect(operation.platform == .linuxAMD64)

        if case .registry(let ref) = operation.source {
            #expect(ref.stringValue == "alpine:3.18")
        } else {
            Issue.record("Expected registry source")
        }
    }

    @Test func imageOperationFromScratch() throws {
        let operation = ImageOperation(source: .scratch)

        #expect(operation.platform == nil)  // Default platform

        if case .scratch = operation.source {
            // Expected
        } else {
            Issue.record("Expected scratch source")
        }
    }

    @Test func imageOperationFromOCILayout() throws {
        let operation = ImageOperation(
            source: .ociLayout(path: "/path/to/build/context", tag: "custom"),
            platform: .linuxARM64
        )

        if case .ociLayout(let path, let tag) = operation.source {
            #expect(path == "/path/to/build/context")
            #expect(tag == "custom")
        } else {
            Issue.record("Expected ociLayout source")
        }
    }

    // MARK: - Operation Visitor Pattern Tests

    class TestOperationVisitor: OperationVisitor {
        typealias Result = String

        var visitedOperations: [String] = []

        func visit(_ operation: ExecOperation) throws -> String {
            visitedOperations.append("exec")
            return "Exec: \(operation.command.displayString)"
        }

        func visit(_ operation: FilesystemOperation) throws -> String {
            visitedOperations.append("filesystem")
            return "Filesystem: \(operation.action) to \(operation.destination)"
        }

        func visit(_ operation: MetadataOperation) throws -> String {
            visitedOperations.append("metadata")
            return "Metadata: \(operation.action)"
        }

        func visit(_ operation: ImageOperation) throws -> String {
            visitedOperations.append("image")
            return "Image: \(operation.source)"
        }

        func visitUnknown(_ operation: any ContainerBuildIR.Operation) throws -> String {
            visitedOperations.append("unknown")
            return "Unknown: \(operation.operationKind)"
        }
    }

    @Test func operationVisitorPattern() throws {
        let operations: [any ContainerBuildIR.Operation] = [
            ExecOperation(command: .shell("echo test")),
            FilesystemOperation(
                action: .copy,
                source: .context(ContextSource(paths: ["file.txt"])),
                destination: "/app/"
            ),
            MetadataOperation(action: .setEnv(key: "TEST", value: .literal("value"))),
            ImageOperation(source: .registry(ImageReference(parsing: "alpine")!)),
        ]

        let visitor = TestOperationVisitor()
        var results: [String] = []

        for operation in operations {
            let result = try operation.accept(visitor)
            results.append(result)
        }

        #expect(visitor.visitedOperations == ["exec", "filesystem", "metadata", "image"])
        #expect(results.count == 4)
        #expect(results[0].hasPrefix("Exec:"))
        #expect(results[1].hasPrefix("Filesystem:"))
        #expect(results[2].hasPrefix("Metadata:"))
        #expect(results[3].hasPrefix("Image:"))
    }

    // MARK: - Operation Serialization Tests

    @Test func operationSerialization() throws {
        let operations: [any ContainerBuildIR.Operation] = [
            ExecOperation(
                command: .exec(["npm", "install"]),
                environment: Environment([(key: "NODE_ENV", value: .literal("production"))]),
                user: .uid(1000)
            ),
            FilesystemOperation(
                action: .copy,
                source: .context(ContextSource(paths: ["src/"])),
                destination: "/app/src/",
                fileMetadata: FileMetadata(
                    ownership: Ownership(user: .numeric(id: 1000), group: .numeric(id: 1000)),
                    permissions: .mode(0o755)
                )
            ),
            MetadataOperation(
                action: .setLabel(key: "version", value: "1.0.0")
            ),
            ImageOperation(
                source: .registry(ImageReference(parsing: "node:18")!),
                platform: .linuxAMD64
            ),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for operation in operations {
            // Test that each operation type can be encoded and decoded
            let data: Data

            switch operation {
            case let execOp as ExecOperation:
                data = try encoder.encode(execOp)
                let decoded = try decoder.decode(ExecOperation.self, from: data)
                #expect(decoded.command.displayString == execOp.command.displayString)
                #expect(decoded.user == execOp.user)

            case let fsOp as FilesystemOperation:
                data = try encoder.encode(fsOp)
                let decoded = try decoder.decode(FilesystemOperation.self, from: data)
                #expect(decoded.action == fsOp.action)
                #expect(decoded.destination == fsOp.destination)

            case let metaOp as MetadataOperation:
                data = try encoder.encode(metaOp)
                _ = try decoder.decode(MetadataOperation.self, from: data)
            // Note: MetadataAction comparison would need custom implementation

            case let imageOp as ImageOperation:
                data = try encoder.encode(imageOp)
                let decoded = try decoder.decode(ImageOperation.self, from: data)
                #expect(decoded.platform == imageOp.platform)

            default:
                Issue.record("Unexpected operation type")
            }
        }
    }

    // MARK: - Operation Metadata Tests

    @Test func operationMetadata() throws {
        let sourceLocation = SourceLocation(
            file: "Dockerfile",
            line: 15,
            column: 5
        )

        let metadata = OperationMetadata(
            comment: "Install application dependencies",
            sourceLocation: sourceLocation
        )

        let operation = ExecOperation(
            command: .shell("npm install"),
            metadata: metadata
        )

        #expect(operation.metadata.comment == "Install application dependencies")
        #expect(operation.metadata.sourceLocation?.file == "Dockerfile")
        #expect(operation.metadata.sourceLocation?.line == 15)
    }

    // MARK: - Complex Operation Tests

    @Test func complexExecOperation() throws {
        let complexOperation = ExecOperation(
            command: .shell("cd /app && npm ci --only=production && npm run build"),
            environment: Environment([
                (key: "NODE_ENV", value: .literal("production")),
                (key: "BUILD_TARGET", value: .buildArg("TARGET")),
                (key: "CACHE_DIR", value: .literal("/tmp/cache")),
            ]),
            mounts: [
                Mount(
                    type: .cache,
                    target: "/tmp/cache",
                    source: .local("build-cache"),
                    options: MountOptions(sharing: .shared)
                ),
                Mount(
                    type: .secret,
                    target: "/run/secrets/npmrc",
                    source: .secret("npmrc"),
                    options: MountOptions(readOnly: true, mode: 0o600)
                ),
            ],
            workingDirectory: "/app",
            user: .uidGid(uid: 1000, gid: 1000),
            network: .default,
            security: SecurityOptions(
                privileged: false,
                noNewPrivileges: true
            ),
            metadata: OperationMetadata(
                comment: "Build application with caching and secrets"
            )
        )

        #expect(complexOperation.command.displayString.contains("npm ci"))
        #expect(complexOperation.environment.variables.count == 3)
        #expect(complexOperation.mounts.count == 2)
        #expect(complexOperation.workingDirectory == "/app")
        #expect(complexOperation.user != nil)
        #expect(complexOperation.security.noNewPrivileges == true)
        #expect(complexOperation.metadata.comment?.contains("Build application") == true)
    }

    @Test func complexFilesystemOperation() throws {
        let complexOperation = FilesystemOperation(
            action: .copy,
            source: .stage(.named("builder"), paths: ["/app/dist/**/*", "/app/package.json"]),
            destination: "/usr/share/nginx/html/",
            fileMetadata: FileMetadata(
                ownership: Ownership(user: .named(id: "nginx"), group: .named(id: "nginx")),
                permissions: .mode(0o644),
                timestamps: Timestamps(
                    created: Date(),
                    modified: Date()
                )
            ),
            metadata: OperationMetadata(
                comment: "Copy built assets from builder stage",
                sourceLocation: SourceLocation(file: "Dockerfile", line: 25, column: 1)
            )
        )

        if case .stage(let stageRef, let paths) = complexOperation.source {
            if case .named(let name) = stageRef {
                #expect(name == "builder")
            }
            #expect(paths.count == 2)
            #expect(paths.contains("/app/dist/**/*"))
        } else {
            Issue.record("Expected stage source")
        }

        #expect(complexOperation.destination == "/usr/share/nginx/html/")
        // Check fileMetadata exists and has expected values
        #expect(complexOperation.metadata.comment?.contains("built assets") == true)
    }

    // MARK: - Edge Cases and Error Conditions

    @Test func emptyOperations() throws {
        // Test operations with minimal/empty configurations
        let minimalExec = ExecOperation(command: .exec([]))
        #expect(minimalExec.command.displayString == "")
        #expect(minimalExec.mounts.isEmpty)

        let minimalFilesystem = FilesystemOperation(
            action: .copy,
            source: .context(ContextSource(paths: [])),
            destination: ""
        )
        #expect(minimalFilesystem.destination == "")

        if case .context(let ctx) = minimalFilesystem.source {
            #expect(ctx.paths.isEmpty)
        }
    }

    @Test func operationEquality() throws {
        let exec1 = ExecOperation(command: .shell("echo test"))
        let exec2 = ExecOperation(command: .shell("echo test"))
        let exec3 = ExecOperation(command: .shell("echo different"))

        #expect(exec1 == exec2)
        #expect(exec1 != exec3)

        let fs1 = FilesystemOperation(
            action: .copy,
            source: .context(ContextSource(paths: ["file.txt"])),
            destination: "/app/"
        )
        let fs2 = FilesystemOperation(
            action: .copy,
            source: .context(ContextSource(paths: ["file.txt"])),
            destination: "/app/"
        )

        #expect(fs1 == fs2)
    }

    @Test func operationHashing() throws {
        let exec1 = ExecOperation(command: .shell("echo test"))
        let exec2 = ExecOperation(command: .shell("echo different"))
        let fs1 = FilesystemOperation(
            action: .copy,
            source: .context(ContextSource(paths: ["file.txt"])),
            destination: "/app/"
        )

        let operations: Set<AnyHashable> = Set([
            AnyHashable(exec1),
            AnyHashable(exec2),
            AnyHashable(fs1),
        ])

        #expect(operations.count == 3)

        // Test that identical operations hash to the same value
        let exec1_copy = ExecOperation(command: .shell("echo test"))
        let exec2_copy = ExecOperation(command: .shell("echo test"))

        var hasher1 = Hasher()
        var hasher2 = Hasher()

        exec1_copy.hash(into: &hasher1)
        exec2_copy.hash(into: &hasher2)

        #expect(hasher1.finalize() == hasher2.finalize())
    }
}
