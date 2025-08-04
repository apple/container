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

import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerBuildIR
@testable import ContainerBuildReporting

struct GraphBuilderTests {

    // MARK: - Complex Multi-Stage Scenarios

    @Test func complexMultiStageNodeJSBuild() throws {
        guard let nodeRef = ImageReference(parsing: "node:18-alpine"),
            let nginxRef = ImageReference(parsing: "nginx:alpine")
        else {
            Issue.record("Failed to parse image references")
            return
        }

        let graph = try GraphBuilder.multiStage { builder in
            // Dependencies stage - install and cache node_modules
            try builder
                .stage(name: "deps", from: nodeRef)
                .workdir("/app")
                .copyFromContext(paths: ["package*.json"], to: "./")
                .run("npm ci --only=production && npm cache clean --force")

            // Build stage - compile TypeScript and build assets
            try builder
                .stage(name: "build", from: nodeRef)
                .workdir("/app")
                .copyFromStage(.named("deps"), paths: ["/app/node_modules"], to: "/app/node_modules")
                .copyFromContext(paths: ["tsconfig.json", "webpack.config.js", "src/"], to: "./")
                .run("npm run build")

            // Runtime stage - serve with nginx
            try builder
                .stage(name: "runtime", from: nginxRef)
                .copyFromStage(.named("build"), paths: ["/app/dist"], to: "/usr/share/nginx/html")
                .copyFromContext(paths: ["nginx.conf"], to: "/etc/nginx/nginx.conf")
                .expose(80)
                .cmd(.exec(["nginx", "-g", "daemon off;"]))
        }

        #expect(graph.stages.count == 3)
        #expect(graph.stages[0].name == "deps")
        #expect(graph.stages[1].name == "build")
        #expect(graph.stages[2].name == "runtime")

        // Verify stage dependencies
        let buildDeps = graph.stages[1].stageDependencies()
        #expect(buildDeps.contains(.named("deps")))

        let runtimeDeps = graph.stages[2].stageDependencies()
        #expect(runtimeDeps.contains(.named("build")))

        // Validate the complex graph
        let validator = StandardValidator()
        let result = validator.validate(graph)
        #expect(result.isValid, "Complex multi-stage build should be valid: \(result.errors)")
    }

    @Test func fourStageGoMicroserviceBuild() throws {
        guard let goRef = ImageReference(parsing: "golang:1.21-alpine"),
            let scratchRef = ImageReference(parsing: "scratch")
        else {
            Issue.record("Failed to parse image references")
            return
        }

        let graph = try GraphBuilder.multiStage { builder in
            // Base tools stage
            try builder
                .stage(name: "tools", from: goRef)
                .run("apk add --no-cache git ca-certificates")
                .workdir("/tools")
                .run("go install github.com/swaggo/swag/cmd/swag@latest")

            // Dependency stage
            try builder
                .stage(name: "deps", from: goRef)
                .workdir("/src")
                .copyFromContext(paths: ["go.mod", "go.sum"], to: "./")
                .run("go mod download")

            // Build stage
            try builder
                .stage(name: "build", from: goRef)
                .copyFromStage(.named("tools"), paths: ["/go/bin/swag"], to: "/usr/local/bin/")
                .workdir("/src")
                .copyFromStage(.named("deps"), paths: ["/go/pkg"], to: "/go/pkg")
                .copyFromContext(paths: [".", "!**/*_test.go"], to: "./")
                .run("swag init -g cmd/server/main.go")
                .run("CGO_ENABLED=0 GOOS=linux go build -ldflags='-w -s' -o /app cmd/server/main.go")

            // Runtime stage
            try builder
                .stage(from: scratchRef)
                .copyFromStage(.named("tools"), paths: ["/etc/ssl/certs/ca-certificates.crt"], to: "/etc/ssl/certs/")
                .copyFromStage(.named("build"), paths: ["/app"], to: "/app")
                .user(.uid(65534))  // nobody user
                .expose(8080)
                .entrypoint(.exec(["/app"]))
        }

        #expect(graph.stages.count == 4)

        // Verify complex dependency chain
        let buildStage = graph.stages[2]
        let buildDeps = buildStage.stageDependencies()
        #expect(buildDeps.contains(.named("tools")))
        #expect(buildDeps.contains(.named("deps")))

        let runtimeStage = graph.stages[3]
        let runtimeDeps = runtimeStage.stageDependencies()
        #expect(runtimeDeps.contains(.named("tools")))
        #expect(runtimeDeps.contains(.named("build")))
    }

    // MARK: - Build Arguments and Environment

    @Test func buildArgumentPropagation() throws {
        guard let nodeRef = ImageReference(parsing: "node:18") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let graph = try GraphBuilder.multiStage { builder in
            try builder
                .stage(name: "build", from: nodeRef)
                .arg("NODE_ENV", defaultValue: "development")
                .arg("BUILD_VERSION", defaultValue: "dev")
                .arg("API_URL")
                .workdir("/app")
                .copyFromContext(paths: ["package.json"], to: "./")
                .run("npm install --omit=dev")
                .env("NODE_ENV", "production")
                .env("BUILD_VERSION", "1.0.0")
                .env("API_URL", "https://api.example.com")
                .copyFromContext(paths: ["src/"], to: "./src/")
                .run("npm run build")
        }

        #expect(graph.buildArgs.count == 2)
        #expect(graph.buildArgs["NODE_ENV"] == "development")
        #expect(graph.buildArgs["BUILD_VERSION"] == "dev")
        // API_URL has no default value so it's not included in buildArgs

        // Verify ARG instructions in stage
        let stage = graph.stages[0]
        let argOps = stage.nodes.compactMap { node in
            node.operation as? MetadataOperation
        }.filter { meta in
            if case .declareArg = meta.action { return true }
            return false
        }
        #expect(argOps.count == 3)

        // Verify ENV instructions reference build args
        let envOps = stage.nodes.compactMap { node in
            node.operation as? MetadataOperation
        }.filter { meta in
            if case .setEnv = meta.action { return true }
            return false
        }
        #expect(envOps.count == 3)
    }

    // MARK: - Platform-Specific Builds

    @Test func multiPlatformBuild() throws {
        guard let baseRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let graph = try GraphBuilder.singleStage(from: baseRef, platform: Platform.linuxAMD64) { builder in
            try builder
                .platforms(Platform.linuxAMD64, Platform.linuxARM64)
                .run("apk add --no-cache curl")
                .workdir("/app")
                .copyFromContext(paths: ["app.sh"], to: "/app/")
                .run("chmod +x /app/app.sh")
                .entrypoint(.exec(["/app/app.sh"]))
        }

        #expect(graph.targetPlatforms.count == 2)
        #expect(graph.targetPlatforms.contains(Platform.linuxAMD64))
        #expect(graph.targetPlatforms.contains(Platform.linuxARM64))

        // Verify base image has platform constraints
        let stage = graph.stages[0]
        let imageOp = stage.base
        #expect(imageOp.platform != nil)
    }

    @Test func platformSpecificStages() throws {
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let graph = try GraphBuilder.multiStage { builder in
            // Linux AMD64 optimized stage
            try builder
                .stage(name: "linux-amd64", from: alpineRef, platform: Platform.linuxAMD64)
                .run("apk add --no-cache glibc-compat")
                .copyFromContext(paths: ["bin/app-linux-amd64"], to: "/usr/local/bin/app")

            // Linux ARM64 stage
            try builder
                .stage(name: "linux-arm64", from: alpineRef, platform: Platform.linuxARM64)
                .run("apk add --no-cache ca-certificates")
                .copyFromContext(paths: ["bin/app-linux-arm64"], to: "/usr/local/bin/app")

            // Final stage that copies from platform-specific stage
            try builder
                .stage(from: alpineRef)
                .copyFromStage(.named("linux-amd64"), paths: ["/usr/local/bin/app"], to: "/usr/local/bin/")
                .copyFromStage(.named("linux-arm64"), paths: ["/usr/local/bin/app"], to: "/usr/local/bin/")
                .entrypoint(.exec(["/usr/local/bin/app"]))
        }

        #expect(graph.stages.count == 3)

        // Verify platform-specific stages
        #expect(graph.stages[0].name == "linux-amd64")
        #expect(graph.stages[1].name == "linux-arm64")

        let amd64ImageOp = graph.stages[0].base
        #expect(amd64ImageOp.platform == Platform.linuxAMD64)

        let arm64ImageOp = graph.stages[1].base
        #expect(arm64ImageOp.platform == Platform.linuxARM64)
    }

    // MARK: - Error Conditions

    @Test func invalidStageReference() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        #expect(throws: Error.self) {
            try GraphBuilder.multiStage { builder in
                try builder
                    .stage(name: "base", from: alpineRef)
                    .run("echo hello")

                try builder
                    .stage(name: "app", from: alpineRef)
                    .copyFromStage(.named("nonexistent"), paths: ["/file"], to: "/")
            }
        }
    }

    @Test func circularStageDependency() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // This should create a circular dependency through stage references
        // GraphBuilder should throw BuildGraphError for cyclic dependencies
        #expect(throws: BuildGraphError.self) {
            try GraphBuilder.multiStage { builder in
                try builder
                    .stage(name: "stage1", from: alpineRef)
                    .copyFromStage(.named("stage2"), paths: ["/file1"], to: "/file1")

                try builder
                    .stage(name: "stage2", from: alpineRef)
                    .copyFromStage(.named("stage1"), paths: ["/file2"], to: "/file2")
            }
        }
    }

    @Test func validEntrypointAndCmdSequence() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // CMD after ENTRYPOINT is a valid and common Docker pattern
        // ENTRYPOINT defines the executable, CMD provides default arguments
        let graph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            try builder
                .entrypoint(.exec(["/app"]))  // Set entrypoint first
                .cmd(.shell("echo override"))  // CMD after ENTRYPOINT is valid
        }

        #expect(graph.stages.count == 1)
        #expect(graph.stages[0].nodes.count == 2)

        // Verify the operations exist and are in the correct order
        let nodes = graph.stages[0].nodes

        let entrypointNode = nodes.first { node in
            if let metaOp = node.operation as? MetadataOperation,
                case .setEntrypoint = metaOp.action
            {
                return true
            }
            return false
        }
        #expect(entrypointNode != nil, "Should have ENTRYPOINT operation")

        let cmdNode = nodes.first { node in
            if let metaOp = node.operation as? MetadataOperation,
                case .setCmd = metaOp.action
            {
                return true
            }
            return false
        }
        #expect(cmdNode != nil, "Should have CMD operation")

        // Validate the graph structure
        let validator = StandardValidator()
        let result = validator.validate(graph)
        #expect(result.isValid, "ENTRYPOINT + CMD sequence should be valid: \(result.errors)")
    }

    @Test func emptyStage() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Empty stage should be valid but might generate warnings
        let graph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            // Intentionally empty - just the base image
        }

        #expect(graph.stages.count == 1)
        #expect(graph.stages[0].nodes.isEmpty, "Empty stage should have no nodes")

        let validator = StandardValidator()
        let result = validator.validate(graph)
        #expect(result.isValid, "Empty stage should be structurally valid")
    }

    // MARK: - Advanced GraphBuilder Features

    @Test func conditionalInstructions() throws {
        guard let nodeRef = ImageReference(parsing: "node:18") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let isDevelopment = false

        let graph = try GraphBuilder.singleStage(from: nodeRef) { builder in
            try builder
                .workdir("/app")
                .copyFromContext(paths: ["package.json"], to: "./")
                .run("npm install" + (isDevelopment ? "" : " --omit=dev"))
                .copyFromContext(paths: ["src/"], to: "./src/")

            if isDevelopment {
                try builder
                    .env("NODE_ENV", "development")
                    .run("npm run test")
                    .cmd(.shell("npm run dev"))
            } else {
                try builder
                    .env("NODE_ENV", "production")
                    .run("npm run build")
                    .cmd(.exec(["node", "dist/index.js"]))
            }
        }

        // Verify production build path was taken
        let envOps = graph.stages[0].nodes.compactMap { node in
            node.operation as? MetadataOperation
        }.compactMap { meta in
            if case .setEnv(let key, let value) = meta.action,
                key == "NODE_ENV"
            {
                return value
            }
            return nil
        }

        #expect(envOps.contains(.literal("production")))
        #expect(!envOps.contains(.literal("development")))
    }

    @Test func stageWithCustomMetadata() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let graph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            try builder
                .label("version", "1.0.0")
                .label("maintainer", "team@example.com")
                .label("description", "Sample application")
                .workdir("/app")
                .user(.named("appuser"))
                .expose(8080)
        }

        // Verify all metadata operations were added
        let metadataOps = graph.stages[0].nodes.compactMap { $0.operation as? MetadataOperation }

        let labelOps = metadataOps.filter {
            if case .setLabel = $0.action { return true }
            return false
        }
        #expect(labelOps.count == 3)

        let userOps = metadataOps.filter {
            if case .setUser = $0.action { return true }
            return false
        }
        #expect(userOps.count == 1)

        let exposeOps = metadataOps.filter {
            if case .expose = $0.action { return true }
            return false
        }
        #expect(exposeOps.count == 1)
    }

    @Test func complexMountOperations() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let graph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            try builder
                .workdir("/app")
                .run(
                    "apk add --no-cache make gcc",
                    mounts: [
                        Mount(type: .cache, target: "/var/cache/apk"),
                        Mount(type: .secret, target: "/run/secrets/github-token", source: .secret("github-token"), options: MountOptions(mode: 0o400)),
                        Mount(type: .bind, target: "/app/.cache", source: .local("build-cache")),
                    ]
                )
                .copyFromContext(paths: ["Makefile", "src/"], to: "./")
                .run(
                    "make build",
                    mounts: [
                        Mount(type: .cache, target: "/app/.cache", options: MountOptions(sharing: .shared)),
                        Mount(type: .tmpfs, target: "/tmp", options: MountOptions(size: 100_000_000)),
                    ]
                )
        }

        // Verify mount operations exist
        let execOps = graph.stages[0].nodes.compactMap { $0.operation as? ExecOperation }

        let firstRunOp = execOps.first { op in
            op.command.displayString.contains("apk add")
        }
        #expect(firstRunOp?.mounts.count == 3)

        let secondRunOp = execOps.first { op in
            op.command.displayString.contains("make build")
        }
        #expect(secondRunOp?.mounts.count == 2)
    }

    // MARK: - Graph Modification and Builder State

    @Test func builderStatePreservation() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let graph1 = try GraphBuilder.singleStage(from: alpineRef) { stageBuilder in
            try stageBuilder
                .arg("VERSION", defaultValue: "1.0.0")
                .platforms(Platform.linuxAMD64)
                .run("echo 'Build 1'")
        }

        // Verify first graph has our settings
        #expect(graph1.buildArgs["VERSION"] == "1.0.0")
        #expect(graph1.targetPlatforms == [Platform.linuxAMD64])

        // Create second graph with different settings
        let graph2 = try GraphBuilder.singleStage(from: alpineRef) { stageBuilder in
            try stageBuilder
                .arg("VERSION", defaultValue: "2.0.0")
                .platforms(Platform.linuxARM64)
                .run("echo 'Build 2'")
        }

        // Verify second graph has updated settings
        #expect(graph2.buildArgs["VERSION"] == "2.0.0")
        #expect(graph2.targetPlatforms == [Platform.linuxARM64])

        // Verify first graph unchanged
        #expect(graph1.buildArgs["VERSION"] == "1.0.0")
        #expect(graph1.targetPlatforms == [Platform.linuxAMD64])
    }

    @Test func incrementalGraphBuilding() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let graph = try GraphBuilder.multiStage { builder in
            // Build base stage
            try builder
                .stage(name: "base", from: alpineRef)
                .run("apk add --no-cache ca-certificates")
                .workdir("/app")

            // Add dependency stage
            try builder
                .stage(name: "deps", from: alpineRef)
                .copyFromStage(.named("base"), paths: ["/etc/ssl"], to: "/etc/ssl")
                .run("apk add --no-cache curl")

            // Add final stage
            try builder
                .stage(from: alpineRef)
                .copyFromStage(.named("base"), paths: ["/app"], to: "/app")
                .copyFromStage(.named("deps"), paths: ["/usr/bin/curl"], to: "/usr/local/bin/")
                .entrypoint(.exec(["/app/start.sh"]))
        }

        #expect(graph.stages.count == 3)
        #expect(graph.stages[0].name == "base")
        #expect(graph.stages[1].name == "deps")
        #expect(graph.stages[2].name == nil)  // Final stage

        // Verify dependencies are correct
        let finalStageDeps = graph.stages[2].stageDependencies()
        #expect(finalStageDeps.contains(.named("base")))
        #expect(finalStageDeps.contains(.named("deps")))
    }
}
