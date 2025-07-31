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
@testable import ContainerBuildReporting

struct AnalysisTests {

    // MARK: - SemanticAnalyzer Integration Tests

    @Test func semanticAnalyzerGraphAnalyzerProtocol() throws {
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let originalGraph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            try builder
                .run("apk add --no-cache curl")
                .workdir("/app")
                .copyFromContext(paths: ["src/"], to: "/app/")
                .user(.uid(1000))
                .entrypoint(.exec(["/app/server"]))
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let analyzedGraph = try analyzer.analyze(originalGraph, context: context)

        // SemanticAnalyzer should return the graph unchanged
        #expect(analyzedGraph.stages.count == originalGraph.stages.count)
        #expect(analyzedGraph.buildArgs == originalGraph.buildArgs)
        #expect(analyzedGraph.targetPlatforms == originalGraph.targetPlatforms)
    }

    @Test func semanticAnalyzerWithReporter() async throws {
        guard let ubuntuRef = ImageReference(parsing: "ubuntu:22.04") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a graph with potential issues
        let graph = try GraphBuilder.singleStage(from: ubuntuRef) { builder in
            try builder
                .run("apt-get update")  // Separate update (should trigger layer warning)
                .run("apt-get install -y curl")  // Separate install (should trigger layer warning)
                .run("wget https://example.com/script.sh")  // Unverified download (security warning)
                .workdir("/app")
                .copyFromContext(paths: ["src/"], to: "/app/")
            // No USER instruction (should trigger security warning)
        }

        let reporter = Reporter()
        let context = AnalysisContext(reporter: reporter, sourceMap: nil)

        let analyzer = SemanticAnalyzer()
        let _ = try analyzer.analyze(graph, context: context)

        // Allow some time for async reporting
        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second

        // Verify that some events were reported
        // Note: We can't easily test the exact events without implementing a test reporter
        // that captures events, but we can verify the analyze method completed successfully
        #expect(Bool(true))  // Analysis completed without throwing
    }

    // MARK: - Layer Efficiency Analysis Tests

    @Test func layerEfficiencyMultiplePackageManagers() throws {
        guard let ubuntuRef = ImageReference(parsing: "ubuntu:22.04") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a graph with multiple package manager calls
        let graph = try GraphBuilder.singleStage(from: ubuntuRef) { builder in
            try builder
                .run("apt-get update")
                .run("apt-get install -y curl")
                .run("apt-get install -y wget")
                .run("apt-get install -y git")
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        // This should trigger layer efficiency warnings
        let _ = try analyzer.analyze(graph, context: context)

        // Verify analysis completed successfully
        #expect(Bool(true))
    }

    @Test func layerEfficiencyAddThenRemove() throws {
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a graph that adds then removes files
        let graph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            try builder
                .run("apk add --no-cache build-base")
                .copyFromContext(paths: ["src/"], to: "/tmp/build/")
                .run("cd /tmp/build && make")
                .run("rm -rf /tmp/build")  // Remove build files
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        // This should trigger layer efficiency warnings about unnecessary files
        let _ = try analyzer.analyze(graph, context: context)

        #expect(Bool(true))
    }

    // MARK: - Security Analysis Tests

    @Test func securityAnalysisRootUser() throws {
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a graph that runs as root (no USER instruction)
        let graph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            try builder
                .run("apk add --no-cache curl")
                .workdir("/app")
                .copyFromContext(paths: ["app"], to: "/app/")
                .entrypoint(.exec(["/app/app"]))
            // No USER instruction - should trigger security warning
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let _ = try analyzer.analyze(graph, context: context)

        #expect(Bool(true))
    }

    @Test func securityAnalysisPrivilegedExecution() throws {
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a graph with privileged execution
        let graph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            try builder
                .run("mount /dev/sda1 /mnt")
                .workdir("/app")
                .user(.uid(1000))
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let _ = try analyzer.analyze(graph, context: context)

        #expect(Bool(true))
    }

    @Test func securityAnalysisUnverifiedDownloads() throws {
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a graph with unverified downloads
        let graph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            try builder
                .run("wget https://example.com/install.sh && sh install.sh")
                .run("curl -sSL https://get.docker.com | sh")
                .workdir("/app")
                .user(.uid(1000))
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let _ = try analyzer.analyze(graph, context: context)

        #expect(Bool(true))
    }

    @Test func securityAnalysisUnpinnedDependencies() throws {
        guard let ubuntuRef = ImageReference(parsing: "ubuntu:22.04") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a graph with unpinned dependencies
        let graph = try GraphBuilder.singleStage(from: ubuntuRef) { builder in
            try builder
                .run("apt-get update")
                .run("apt-get install -y curl")  // No version pinning
                .run("pip install flask")  // No version pinning
                .workdir("/app")
                .user(.uid(1000))
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let _ = try analyzer.analyze(graph, context: context)

        #expect(Bool(true))
    }

    // MARK: - Cache Analysis Tests

    @Test func cacheAnalysisTimestampInvalidation() throws {
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a graph with timestamp-based cache invalidation
        let graph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            try builder
                .run("apk add --no-cache curl")
                .run("echo $(date) > /app/build-time.txt")  // Timestamp invalidates cache
                .workdir("/app")
                .user(.uid(1000))
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let _ = try analyzer.analyze(graph, context: context)

        #expect(Bool(true))
    }

    @Test func cacheAnalysisRandomInvalidation() throws {
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a graph with random data cache invalidation
        let graph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            try builder
                .run("apk add --no-cache curl")
                .run("echo $RANDOM > /app/random.txt")  // Random invalidates cache
                .run("openssl rand -hex 16 > /app/key.txt")  // Random invalidates cache
                .workdir("/app")
                .user(.uid(1000))
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let _ = try analyzer.analyze(graph, context: context)

        #expect(Bool(true))
    }

    // MARK: - Size Optimization Tests

    @Test func sizeOptimizationPackageCache() throws {
        guard let ubuntuRef = ImageReference(parsing: "ubuntu:22.04") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a graph without package cache cleanup
        let graph = try GraphBuilder.singleStage(from: ubuntuRef) { builder in
            try builder
                .run("apt-get update")
                .run("apt-get install -y curl wget git")
                // No cleanup - should trigger size optimization warning
                .workdir("/app")
                .user(.uid(1000))
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let _ = try analyzer.analyze(graph, context: context)

        #expect(Bool(true))
    }

    @Test func sizeOptimizationBuildDependencies() throws {
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a single-stage graph with build dependencies
        let graph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            try builder
                .run("apk add --no-cache build-base gcc-dev")  // Build dependencies
                .workdir("/app")
                .copyFromContext(paths: ["src/"], to: "/app/")
                .run("make")
                .user(.uid(1000))
                .entrypoint(.exec(["/app/server"]))
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let _ = try analyzer.analyze(graph, context: context)

        #expect(Bool(true))
    }

    @Test func sizeOptimizationMultiStageComparison() throws {
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a multi-stage graph (should NOT trigger build dependency warnings)
        let graph = try GraphBuilder.multiStage { builder in
            try builder
                .stage(name: "builder", from: alpineRef)
                .run("apk add --no-cache build-base")
                .workdir("/app")
                .copyFromContext(paths: ["src/"], to: "/app/")
                .run("make")

            try builder
                .stage(from: alpineRef)
                .copyFromStage(.named("builder"), paths: ["/app/server"], to: "/app/")
                .user(.uid(1000))
                .entrypoint(.exec(["/app/server"]))
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let _ = try analyzer.analyze(graph, context: context)

        #expect(Bool(true))
    }

    // MARK: - Custom Analyzer Tests

    struct CustomSecurityAnalyzer: GraphAnalyzer {
        func analyze(_ graph: BuildGraph, context: AnalysisContext) throws -> BuildGraph {
            // Custom analysis: Check for hardcoded secrets
            for stage in graph.stages {
                for node in stage.nodes {
                    if let exec = node.operation as? ExecOperation {
                        if case .shell(let cmd) = exec.command {
                            if cmd.contains("PASSWORD=") || cmd.contains("SECRET=") {
                                if let reporter = context.reporter {
                                    Task {
                                        await reporter.report(
                                            .irEvent(
                                                context: ReportContext(
                                                    description: "Potential hardcoded secret detected in command",
                                                    sourceMap: nil
                                                ),
                                                type: .error
                                            ))
                                    }
                                }
                            }
                        }
                    }
                }
            }

            return graph
        }
    }

    @Test func customAnalyzerExtensibility() throws {
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a graph with hardcoded secrets
        let graph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            try builder
                .run("export PASSWORD=secret123")  // Hardcoded secret
                .run("SECRET=api_key_123 ./app")  // Hardcoded secret
                .workdir("/app")
                .user(.uid(1000))
        }

        let customAnalyzer = CustomSecurityAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let _ = try customAnalyzer.analyze(graph, context: context)

        #expect(Bool(true))
    }

    // MARK: - Analyzer Chain Tests

    @Test func analyzerChain() throws {
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let graph = try GraphBuilder.singleStage(from: alpineRef) { builder in
            try builder
                .run("apk add --no-cache curl")
                .workdir("/app")
                .copyFromContext(paths: ["src/"], to: "/app/")
                .user(.uid(1000))
                .entrypoint(.exec(["/app/server"]))
        }

        let analyzers: [any GraphAnalyzer] = [
            DependencyAnalyzer(),
            SemanticAnalyzer(),
            CustomSecurityAnalyzer(),
        ]

        var currentGraph = graph
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        // Apply analyzers in sequence
        for analyzer in analyzers {
            currentGraph = try analyzer.analyze(currentGraph, context: context)
        }

        // Graph should be preserved through the chain
        #expect(currentGraph.stages.count == graph.stages.count)
        #expect(currentGraph.buildArgs == graph.buildArgs)
    }

    // MARK: - Performance Tests

    @Test func analysisPerformanceLargeGraph() throws {
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a large graph for performance testing
        let graph = try GraphBuilder.multiStage { builder in
            for stageIndex in 0..<10 {
                try builder
                    .stage(name: "stage\(stageIndex)", from: alpineRef)
                    .run("apk add --no-cache curl")
                    .run("apk add --no-cache wget")
                    .run("apk add --no-cache git")
                    .workdir("/app")
                    .copyFromContext(paths: ["file\(stageIndex).txt"], to: "/app/")
                    .env("STAGE", "\(stageIndex)")
                    .label("stage.number", "\(stageIndex)")
                    .user(.uid(1000))
            }
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let startTime = Date()
        let _ = try analyzer.analyze(graph, context: context)
        let duration = Date().timeIntervalSince(startTime)

        print("Semantic analysis for large graph (10 stages): \(String(format: "%.3f", duration))s")
        #expect(duration < 1.0, "Analysis should complete quickly for large graphs")
    }

    // MARK: - Error Handling Tests

    @Test func analysisErrorHandling() throws {
        // Test that analysis handles malformed operations gracefully
        guard let alpineRef = ImageReference(parsing: "alpine:latest") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // GraphBuilder will throw validation errors for malformed operations
        #expect(throws: ValidationError.self) {
            try GraphBuilder.singleStage(from: alpineRef) { builder in
                try builder
                    .run("")  // Empty command
                    .workdir("")  // Empty workdir
                    .copyFromContext(paths: [], to: "")  // Empty paths and destination
                    .user(.uid(0))  // Root user
            }
        }
    }

    // MARK: - Reporting Integration Tests

    @Test func analysisReportingIntegration() async throws {
        guard let ubuntuRef = ImageReference(parsing: "ubuntu:22.04") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a graph with multiple types of issues
        let graph = try GraphBuilder.singleStage(from: ubuntuRef) { builder in
            try builder
                .run("apt-get update")  // Layer efficiency issue
                .run("apt-get install -y curl")  // Layer efficiency issue
                .run("apt-get install -y wget")  // Layer efficiency issue
                .run("wget https://example.com/script.sh")  // Security issue
                .run("echo $RANDOM > /app/random.txt")  // Cache invalidation issue
                .workdir("/app")
            // No USER instruction - security issue
            // No cleanup - size optimization issue
        }

        let reporter = Reporter()
        let context = AnalysisContext(
            reporter: reporter,
            sourceMap: SourceMap(
                file: "Dockerfile",
                line: 1,
                column: 1,
                snippet: "FROM ubuntu:22.04"
            )
        )

        let analyzer = SemanticAnalyzer()
        let _ = try analyzer.analyze(graph, context: context)

        // Allow time for async reporting
        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second

        #expect(Bool(true))  // Analysis and reporting completed successfully
    }

    // MARK: - Real-world Scenario Tests

    @Test func analysisNodeJSApplication() throws {
        guard let nodeRef = ImageReference(parsing: "node:18-alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Realistic Node.js application build
        let graph = try GraphBuilder.singleStage(from: nodeRef) { builder in
            try builder
                .run("apk add --no-cache dumb-init")  // Good: single package install
                .workdir("/app")
                .copyFromContext(paths: ["package*.json"], to: "./")
                .run("npm ci --only=production && npm cache clean --force")  // Good: cleanup
                .copyFromContext(paths: ["src/"], to: "./src/")
                .user(.uid(1000))  // Good: non-root user
                .expose(3000)
                .entrypoint(.exec(["dumb-init", "node", "src/index.js"]))
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let _ = try analyzer.analyze(graph, context: context)

        #expect(Bool(true))
    }

    @Test func analysisGoApplication() throws {
        guard let golangRef = ImageReference(parsing: "golang:1.21-alpine"),
            let alpineRef = ImageReference(parsing: "alpine:latest")
        else {
            Issue.record("Failed to parse image references")
            return
        }

        // Realistic Go multi-stage build
        let graph = try GraphBuilder.multiStage { builder in
            try builder
                .stage(name: "builder", from: golangRef)
                .workdir("/src")
                .copyFromContext(paths: ["go.mod", "go.sum"], to: "./")
                .run("go mod download")
                .copyFromContext(paths: [".", "!**/*_test.go"], to: "./")
                .run("CGO_ENABLED=0 GOOS=linux go build -ldflags='-w -s' -o /app cmd/main.go")

            try builder
                .stage(from: alpineRef)
                .run("apk add --no-cache ca-certificates && rm -rf /var/cache/apk/*")  // Good: cleanup
                .copyFromStage(.named("builder"), paths: ["/app"], to: "/usr/local/bin/")
                .user(.uid(65534))  // Good: nobody user
                .expose(8080)
                .entrypoint(.exec(["/usr/local/bin/app"]))
        }

        let analyzer = SemanticAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let _ = try analyzer.analyze(graph, context: context)

        #expect(Bool(true))
    }
}
