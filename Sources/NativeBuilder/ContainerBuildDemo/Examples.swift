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

/// Example demonstrating how to build an IR graph programmatically.
///
/// This example creates a multi-stage Node.js application build.
public enum IRExample {

    /// Create a simple single-stage build.
    public static func createSimpleBuild() throws -> BuildGraph {
        guard let baseImage = ImageReference(parsing: "ubuntu:22.04") else {
            throw ReferenceError.invalidFormat("ubuntu:22.04")
        }

        return try GraphBuilder.singleStage(
            from: baseImage,
            platform: .linuxAMD64
        ) { builder in
            try builder
                .run("apt-get update && apt-get install -y curl")
                .workdir("/app")
                .copyFromContext(paths: ["package.json", "src/"], to: "/app/")
                .run("npm install")
                .env("NODE_ENV", "production")
                .expose(3000)
                .cmd(Command.exec(["node", "src/index.js"]))
        }
    }

    /// Create a realistic multi-stage build showing actual parallelism
    public static func createParallelBuild(reporter: Reporter? = nil) throws -> BuildGraph {
        // In container builds, true parallelism happens between stages or with independent resources

        guard let nodeImage = ImageReference(parsing: "node:18-alpine"),
            let goImage = ImageReference(parsing: "golang:1.21-alpine"),
            let alpineImage = ImageReference(parsing: "alpine:3.18")
        else {
            throw ReferenceError.invalidFormat("Invalid image reference")
        }

        return try GraphBuilder.multiStage(reporter: reporter) { builder in
            // Stage 1: Build frontend assets
            try builder
                .stage(name: "frontend-builder", from: nodeImage)
                .workdir("/frontend")
                .copyFromContext(paths: ["frontend/package*.json"], to: "./")
                .run("npm ci")
                .copyFromContext(paths: ["frontend/"], to: "./")
                .run("npm run build")

            // Stage 2: Build backend
            try builder
                .stage(name: "backend-builder", from: goImage)
                .workdir("/backend")
                .copyFromContext(paths: ["go.mod", "go.sum"], to: "./")
                .run("go mod download")
                .copyFromContext(paths: ["*.go", "cmd/", "internal/"], to: "./")
                .run("CGO_ENABLED=0 go build -o server ./cmd/server")

            // Stage 3: Runtime - depends on both builders
            try builder
                .stage(name: "runtime", from: alpineImage)
                .copyFromStage(.named("frontend-builder"), paths: ["/frontend/dist"], to: "/app/static")
                .copyFromStage(.named("backend-builder"), paths: ["/backend/server"], to: "/app/server")
                .run("chmod +x /app/server")
                .expose(8080)
                .cmd(.exec(["/app/server"]))
        }
    }

    /// Create a multi-stage build for a Go application.
    public static func createMultiStageBuild() throws -> BuildGraph {
        try GraphBuilder.multiStage { builder in
            // Build stage
            guard let builderImage = ImageReference(parsing: "golang:1.21-alpine") else {
                throw ReferenceError.invalidFormat("golang:1.21-alpine")
            }

            try builder
                .stage(
                    name: "builder",
                    from: builderImage
                )
                .workdir("/build")
                .copyFromContext(paths: ["go.mod", "go.sum"], to: "./")
                .run("go mod download")
                .copyFromContext(paths: ["*.go"], to: "./")
                .run("CGO_ENABLED=0 go build -o app")

            // Runtime stage
            try builder
                .scratch(name: "runtime")
                .copyFromStage(
                    .named("builder"),
                    paths: ["/build/app"],
                    to: "/app",
                    chmod: .mode(0o755)
                )
                .copyFromStage(
                    .named("builder"),
                    paths: ["/etc/ssl/certs/ca-certificates.crt"],
                    to: "/etc/ssl/certs/"
                )
                .user(.uid(1000))
                .entrypoint(.exec(["/app"]))
        }
    }

    /// Create a Python application with best practices.
    public static func createPythonBuild() throws -> BuildGraph {
        let graph = try BuildGraph(
            stages: [
                // Dependencies stage
                BuildStage(
                    name: "dependencies",
                    base: {
                        guard let pythonImage = ImageReference(parsing: "python:3.11-slim") else {
                            throw ReferenceError.invalidFormat("python:3.11-slim")
                        }
                        return ImageOperation(
                            source: .registry(pythonImage),
                            platform: .linuxAMD64
                        )
                    }(),
                    nodes: [
                        BuildNode(
                            operation: MetadataOperation(
                                action: .setWorkdir(path: "/app")
                            )
                        ),
                        BuildNode(
                            operation: FilesystemOperation(
                                action: .copy,
                                source: .context(ContextSource(paths: ["requirements.txt"])),
                                destination: "/app/"
                            )
                        ),
                        BuildNode(
                            operation: ExecOperation(
                                command: .shell("pip install --user --no-cache-dir -r requirements.txt")
                            )
                        ),
                    ]
                ),

                // Application stage
                BuildStage(
                    name: "app",
                    base: {
                        guard let pythonImage = ImageReference(parsing: "python:3.11-slim") else {
                            throw ReferenceError.invalidFormat("python:3.11-slim")
                        }
                        return ImageOperation(
                            source: .registry(pythonImage),
                            platform: .linuxAMD64
                        )
                    }(),
                    nodes: [
                        // Copy dependencies from first stage
                        BuildNode(
                            operation: FilesystemOperation(
                                action: .copy,
                                source: .stage(.named("dependencies"), paths: ["/root/.local"]),
                                destination: "/root/.local"
                            )
                        ),
                        // Set up application
                        BuildNode(
                            operation: MetadataOperation(
                                action: .setWorkdir(path: "/app")
                            )
                        ),
                        BuildNode(
                            operation: FilesystemOperation(
                                action: .copy,
                                source: .context(ContextSource(paths: ["*.py", "src/"])),
                                destination: "/app/"
                            )
                        ),
                        // Configure runtime
                        BuildNode(
                            operation: MetadataOperation(
                                action: .setEnv(
                                    key: "PYTHONPATH",
                                    value: .literal("/root/.local/lib/python3.11/site-packages")
                                )
                            )
                        ),
                        BuildNode(
                            operation: MetadataOperation(
                                action: .setUser(user: .uidGid(uid: 1000, gid: 1000))
                            )
                        ),
                        BuildNode(
                            operation: MetadataOperation(
                                action: .expose(port: PortSpec(port: 8000))
                            )
                        ),
                        BuildNode(
                            operation: MetadataOperation(
                                action: .setHealthcheck(
                                    healthcheck: Healthcheck(
                                        test: .shell("curl -f http://localhost:8000/health || exit 1"),
                                        interval: 30,
                                        timeout: 3,
                                        retries: 3
                                    )
                                )
                            )
                        ),
                        BuildNode(
                            operation: MetadataOperation(
                                action: .setCmd(command: .exec(["python", "main.py"]))
                            )
                        ),
                    ]
                ),
            ],
            targetPlatforms: [.linuxAMD64, .linuxARM64]
        )

        return graph
    }

    /// Demonstrate advanced features like cache mounts and secrets.
    public static func createAdvancedBuild() throws -> BuildGraph {
        guard let nodeImage = ImageReference(parsing: "node:18-alpine") else {
            throw ReferenceError.invalidFormat("node:18-alpine")
        }

        return try GraphBuilder.singleStage(
            from: nodeImage
        ) { builder in
            try builder
                .workdir("/app")

                // Cache mount for package manager
                .run(
                    "npm ci",
                    mounts: [
                        Mount(
                            type: .cache,
                            target: "/root/.npm",
                            options: MountOptions(sharing: .shared)
                        )
                    ]
                )

                // Secret mount for private registry
                .run(
                    "npm install @private/package",
                    mounts: [
                        Mount(
                            type: .secret,
                            target: "/root/.npmrc",
                            source: .secret("npm-token"),
                            options: MountOptions(readOnly: true, mode: 0o600)
                        )
                    ]
                )

                // Build with tmpfs for temporary files
                .run(
                    "npm run build",
                    mounts: [
                        Mount(
                            type: .tmpfs,
                            target: "/tmp",
                            options: MountOptions(size: 1024 * 1024 * 1024)  // 1GB
                        )
                    ]
                )

                // Multi-platform metadata
                .label("org.opencontainers.image.source", "https://github.com/example/app")
                .label("org.opencontainers.image.version", "${VERSION}")
                .label("org.opencontainers.image.created", "${BUILD_DATE}")
        }
    }

    /// Validate and analyze a build graph.
    public static func analyzeGraph(_ graph: BuildGraph) {
        // Validate
        let validator = StandardValidator()
        let validationResult = validator.validate(graph)

        print("Validation Results:")
        print("  Errors: \(validationResult.errors.count)")
        for error in validationResult.errors {
            print("    - \(error)")
        }
        print("  Warnings: \(validationResult.warnings.count)")
        for warning in validationResult.warnings {
            print("    - \(warning.message)")
            if let suggestion = warning.suggestion {
                print("      Suggestion: \(suggestion)")
            }
        }

        // Analyze with reporter
        print("\nSemantic Analysis:")

        // Graph statistics
        let stats = graph.analyze()
        print("\nGraph Statistics:")
        print("  Stages: \(stats.stageCount)")
        print("  Operations: \(stats.operationCount)")
        print("  Critical Path: \(stats.criticalPathLength) operations")
    }
}
