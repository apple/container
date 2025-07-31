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

struct DependencyAnalysisTests {

    // MARK: - DependencyAnalyzer Tests

    @Test func sequentialDependenciesInStage() throws {
        // Create a stage with multiple operations that should depend on each other
        let baseOp = ImageOperation(source: .registry(ImageReference(parsing: "alpine")!))
        let stage = BuildStage(
            name: "test",
            base: baseOp,
            nodes: [
                BuildNode(
                    operation: ExecOperation(command: .shell("echo 'step 1'")),
                    dependencies: []
                ),
                BuildNode(
                    operation: ExecOperation(command: .shell("echo 'step 2'")),
                    dependencies: []
                ),
                BuildNode(
                    operation: ExecOperation(command: .shell("echo 'step 3'")),
                    dependencies: []
                ),
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let analyzer = DependencyAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let analyzedGraph = try analyzer.analyze(graph, context: context)
        let analyzedStage = analyzedGraph.stages[0]

        // First node should have no dependencies
        #expect(analyzedStage.nodes[0].dependencies.isEmpty)

        // Second node should depend on first
        #expect(analyzedStage.nodes[1].dependencies.contains(analyzedStage.nodes[0].id))

        // Third node should depend on second
        #expect(analyzedStage.nodes[2].dependencies.contains(analyzedStage.nodes[1].id))

        // Verify chain: node[0] -> node[1] -> node[2]
        #expect(analyzedStage.nodes[1].dependencies.count == 1)
        #expect(analyzedStage.nodes[2].dependencies.count == 1)
    }

    @Test func crossStageDependenciesWithCopyFrom() throws {
        guard let alpineRef = ImageReference(parsing: "alpine"),
            let ubuntuRef = ImageReference(parsing: "ubuntu")
        else {
            Issue.record("Failed to parse image references")
            return
        }

        // Create multi-stage build with COPY --from dependencies
        let buildStage = BuildStage(
            name: "builder",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(command: .shell("echo 'building...'")),
                    dependencies: []
                ),
                BuildNode(
                    operation: ExecOperation(command: .shell("echo 'app built' > /app/binary")),
                    dependencies: []
                ),
            ]
        )

        let runtimeStage = BuildStage(
            name: "runtime",
            base: ImageOperation(source: .registry(ubuntuRef)),
            nodes: [
                BuildNode(
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .stage(.named("builder"), paths: ["/app/binary"]),
                        destination: "/usr/local/bin/app"
                    ),
                    dependencies: []
                ),
                BuildNode(
                    operation: MetadataOperation(action: .setEntrypoint(command: .exec(["/usr/local/bin/app"]))),
                    dependencies: []
                ),
            ]
        )

        let graph = try BuildGraph(stages: [buildStage, runtimeStage])
        let analyzer = DependencyAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let analyzedGraph = try analyzer.analyze(graph, context: context)

        // Verify cross-stage dependency was established
        let analyzedRuntime = analyzedGraph.stages[1]
        let copyNode = analyzedRuntime.nodes[0]
        let lastBuildNode = analyzedGraph.stages[0].nodes.last!

        #expect(
            copyNode.dependencies.contains(lastBuildNode.id),
            "COPY --from should depend on last operation in source stage")

        // Verify intra-stage dependency in runtime stage
        let entrypointNode = analyzedRuntime.nodes[1]
        #expect(
            entrypointNode.dependencies.contains(copyNode.id),
            "Entrypoint should depend on copy operation")
    }

    @Test func stageReferenceResolution() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage1 = BuildStage(
            name: "stage1",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(command: .shell("echo 'stage1' > /file1")),
                    dependencies: []
                )
            ]
        )

        let stage2 = BuildStage(
            name: "stage2",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(command: .shell("echo 'stage2' > /file2")),
                    dependencies: []
                )
            ]
        )

        let finalStage = BuildStage(
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                // Test named reference
                BuildNode(
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .stage(.named("stage1"), paths: ["/file1"]),
                        destination: "/final/file1"
                    ),
                    dependencies: []
                ),
                // Test index reference
                BuildNode(
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .stage(.index(1), paths: ["/file2"]),
                        destination: "/final/file2"
                    ),
                    dependencies: []
                ),
                // Test previous reference
                BuildNode(
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .stage(.previous, paths: ["/file2"]),
                        destination: "/final/file2-prev"
                    ),
                    dependencies: []
                ),
            ]
        )

        let graph = try BuildGraph(stages: [stage1, stage2, finalStage])
        let analyzer = DependencyAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let analyzedGraph = try analyzer.analyze(graph, context: context)
        let analyzedFinal = analyzedGraph.stages[2]

        // Verify named reference dependency
        let namedCopyNode = analyzedFinal.nodes[0]
        let stage1LastNode = analyzedGraph.stages[0].nodes.last!
        #expect(namedCopyNode.dependencies.contains(stage1LastNode.id))

        // Verify index reference dependency
        let indexCopyNode = analyzedFinal.nodes[1]
        let stage2LastNode = analyzedGraph.stages[1].nodes.last!
        #expect(indexCopyNode.dependencies.contains(stage2LastNode.id))

        // Verify previous reference dependency
        let previousCopyNode = analyzedFinal.nodes[2]
        #expect(previousCopyNode.dependencies.contains(stage2LastNode.id))
    }

    @Test func preserveExistingDependencies() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create nodes with existing dependencies
        let node1 = BuildNode(
            operation: ExecOperation(command: .shell("echo 'node1'")),
            dependencies: []
        )

        let node2 = BuildNode(
            operation: ExecOperation(command: .shell("echo 'node2'")),
            dependencies: []
        )

        let node3 = BuildNode(
            operation: ExecOperation(command: .shell("echo 'node3'")),
            dependencies: Set([node1.id])  // Explicitly depends on node1, not node2
        )

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [node1, node2, node3]
        )

        let graph = try BuildGraph(stages: [stage])
        let analyzer = DependencyAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        let analyzedGraph = try analyzer.analyze(graph, context: context)
        let analyzedStage = analyzedGraph.stages[0]

        // Node1 should have no dependencies
        #expect(analyzedStage.nodes[0].dependencies.isEmpty)

        // Node2 should depend on node1 (sequential)
        #expect(analyzedStage.nodes[1].dependencies.contains(analyzedStage.nodes[0].id))

        // Node3 should preserve its explicit dependency on node1
        // and NOT have sequential dependency on node2
        let node3Analyzed = analyzedStage.nodes[2]
        #expect(node3Analyzed.dependencies.contains(node1.id))
        #expect(!node3Analyzed.dependencies.contains(node2.id))
        #expect(node3Analyzed.dependencies.count == 1)
    }

    // MARK: - GraphTraversal Tests

    @Test func topologicalSort() throws {
        // Create a stage with dependencies: A -> B -> C, A -> D -> C
        let nodeA = BuildNode(
            operation: ExecOperation(command: .shell("echo 'A'")),
            dependencies: []
        )
        let nodeD = BuildNode(
            operation: ExecOperation(command: .shell("echo 'D'")),
            dependencies: Set([nodeA.id])
        )
        let nodeB = BuildNode(
            operation: ExecOperation(command: .shell("echo 'B'")),
            dependencies: Set([nodeA.id])
        )
        let nodeC = BuildNode(
            operation: ExecOperation(command: .shell("echo 'C'")),
            dependencies: Set([nodeB.id, nodeD.id])
        )

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .scratch),
            nodes: [nodeC, nodeB, nodeA, nodeD]  // Intentionally out of order
        )

        let sorted = try GraphTraversal.topologicalSort(stage)

        // Find positions in sorted array
        let posA = sorted.firstIndex { $0.id == nodeA.id }!
        let posB = sorted.firstIndex { $0.id == nodeB.id }!
        let posC = sorted.firstIndex { $0.id == nodeC.id }!
        let posD = sorted.firstIndex { $0.id == nodeD.id }!

        // Verify ordering constraints
        #expect(posA < posB, "A should come before B")
        #expect(posA < posD, "A should come before D")
        #expect(posB < posC, "B should come before C")
        #expect(posD < posC, "D should come before C")

        #expect(sorted.count == 4, "All nodes should be included")
    }

    @Test func cycleDetection() throws {
        // Create a cycle: A -> B -> C -> A
        let nodeA = BuildNode(
            operation: ExecOperation(command: .shell("echo 'A'")),
            dependencies: []
        )
        let nodeB = BuildNode(
            operation: ExecOperation(command: .shell("echo 'B'")),
            dependencies: Set([nodeA.id])
        )
        let nodeC = BuildNode(
            operation: ExecOperation(command: .shell("echo 'C'")),
            dependencies: Set([nodeB.id])
        )

        // Create cycle by making A depend on C
        let nodeACyclic = BuildNode(
            id: nodeA.id,
            operation: nodeA.operation,
            dependencies: Set([nodeC.id])
        )

        let stage = BuildStage(
            name: "cyclic",
            base: ImageOperation(source: .scratch),
            nodes: [nodeACyclic, nodeB, nodeC]
        )

        #expect(throws: BuildGraphError.self) {
            try GraphTraversal.topologicalSort(stage)
        }
    }

    @Test func findDependentsAndDependencies() throws {
        // Create dependency chain: A -> B -> C, A -> D
        let nodeA = BuildNode(
            operation: ExecOperation(command: .shell("echo 'A'")),
            dependencies: []
        )
        let nodeB = BuildNode(
            operation: ExecOperation(command: .shell("echo 'B'")),
            dependencies: Set([nodeA.id])
        )
        let nodeC = BuildNode(
            operation: ExecOperation(command: .shell("echo 'C'")),
            dependencies: Set([nodeB.id])
        )
        let nodeD = BuildNode(
            operation: ExecOperation(command: .shell("echo 'D'")),
            dependencies: Set([nodeA.id])
        )

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .scratch),
            nodes: [nodeA, nodeB, nodeC, nodeD]
        )

        // Test finding dependents
        let aDependents = GraphTraversal.findDependents(of: nodeA.id, in: stage)
        #expect(aDependents.contains(nodeB.id))
        #expect(aDependents.contains(nodeC.id))  // Transitive
        #expect(aDependents.contains(nodeD.id))
        #expect(aDependents.count == 3)

        let bDependents = GraphTraversal.findDependents(of: nodeB.id, in: stage)
        #expect(bDependents.contains(nodeC.id))
        #expect(!bDependents.contains(nodeA.id))
        #expect(bDependents.count == 1)

        // Test finding dependencies
        let cDependencies = GraphTraversal.findDependencies(of: nodeC.id, in: stage)
        #expect(cDependencies.contains(nodeB.id))
        #expect(cDependencies.contains(nodeA.id))  // Transitive
        #expect(!cDependencies.contains(nodeD.id))
        #expect(cDependencies.count == 2)

        let aDependencies = GraphTraversal.findDependencies(of: nodeA.id, in: stage)
        #expect(aDependencies.isEmpty, "Root node should have no dependencies")
    }

    @Test func findRootsAndLeaves() throws {
        // Create graph: A -> B -> C, D -> E
        let nodeA = BuildNode(
            operation: ExecOperation(command: .shell("echo 'A'")),
            dependencies: []
        )
        let nodeB = BuildNode(
            operation: ExecOperation(command: .shell("echo 'B'")),
            dependencies: Set([nodeA.id])
        )
        let nodeC = BuildNode(
            operation: ExecOperation(command: .shell("echo 'C'")),
            dependencies: Set([nodeB.id])
        )
        let nodeD = BuildNode(
            operation: ExecOperation(command: .shell("echo 'D'")),
            dependencies: []
        )
        let nodeE = BuildNode(
            operation: ExecOperation(command: .shell("echo 'E'")),
            dependencies: Set([nodeD.id])
        )

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .scratch),
            nodes: [nodeA, nodeB, nodeC, nodeD, nodeE]
        )

        // Test finding roots
        let roots = GraphTraversal.findRoots(in: stage)
        let rootIds = Set(roots.map { $0.id })
        #expect(rootIds.contains(nodeA.id))
        #expect(rootIds.contains(nodeD.id))
        #expect(rootIds.count == 2)

        // Test finding leaves
        let leaves = GraphTraversal.findLeaves(in: stage)
        let leafIds = Set(leaves.map { $0.id })
        #expect(leafIds.contains(nodeC.id))
        #expect(leafIds.contains(nodeE.id))
        #expect(leafIds.count == 2)
    }

    @Test func criticalPath() throws {
        // Create a diamond dependency: A -> B -> D, A -> C -> D
        let nodeA = BuildNode(
            operation: ExecOperation(command: .shell("echo 'A'")),
            dependencies: []
        )
        let nodeB = BuildNode(
            operation: ExecOperation(command: .shell("echo 'B'")),
            dependencies: Set([nodeA.id])
        )
        let nodeC = BuildNode(
            operation: ExecOperation(command: .shell("echo 'C'")),
            dependencies: Set([nodeA.id])
        )
        let nodeD = BuildNode(
            operation: ExecOperation(command: .shell("echo 'D'")),
            dependencies: Set([nodeB.id, nodeC.id])
        )

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .scratch),
            nodes: [nodeA, nodeB, nodeC, nodeD]
        )

        let criticalPath = GraphTraversal.criticalPath(in: stage)

        #expect(criticalPath.count >= 3, "Critical path should have at least 3 nodes")

        // Verify path contains A and D (start and end)
        let pathIds = Set(criticalPath.map { $0.id })
        #expect(pathIds.contains(nodeA.id))
        #expect(pathIds.contains(nodeD.id))
    }

    @Test func depthFirstTraversal() throws {
        // Create dependency chain: A -> B -> C
        let nodeA = BuildNode(
            operation: ExecOperation(command: .shell("echo 'A'")),
            dependencies: []
        )
        let nodeB = BuildNode(
            operation: ExecOperation(command: .shell("echo 'B'")),
            dependencies: Set([nodeA.id])
        )
        let nodeC = BuildNode(
            operation: ExecOperation(command: .shell("echo 'C'")),
            dependencies: Set([nodeB.id])
        )

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .scratch),
            nodes: [nodeC, nodeB, nodeA]  // Out of order
        )

        var visitOrder: [UUID] = []

        try GraphTraversal.depthFirst(stage: stage) { node in
            visitOrder.append(node.id)
        }

        #expect(visitOrder.count == 3)

        // Find positions in visit order
        let posA = visitOrder.firstIndex(of: nodeA.id)!
        let posB = visitOrder.firstIndex(of: nodeB.id)!
        let posC = visitOrder.firstIndex(of: nodeC.id)!

        // DFS should visit dependencies before dependents
        #expect(posA < posB, "A should be visited before B")
        #expect(posB < posC, "B should be visited before C")
    }

    // MARK: - Stage Dependencies Tests

    @Test func findStageDependencies() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage1 = BuildStage(
            name: "build",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(command: .shell("echo 'building...'")),
                    dependencies: []
                )
            ]
        )

        let stage2 = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .stage(.named("build"), paths: ["/app"]),
                        destination: "/test/app"
                    ),
                    dependencies: []
                )
            ]
        )

        let stage3 = BuildStage(
            name: "final",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .stage(.index(0), paths: ["/app"]),
                        destination: "/final/app"
                    ),
                    dependencies: []
                ),
                BuildNode(
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .stage(.previous, paths: ["/test"]),
                        destination: "/final/test"
                    ),
                    dependencies: []
                ),
            ]
        )

        let graph = try BuildGraph(stages: [stage1, stage2, stage3])

        // Test stage 2 dependencies
        let stage2Deps = GraphTraversal.findStageDependencies(of: stage2, in: graph)
        #expect(stage2Deps.contains("build"))
        #expect(stage2Deps.count == 1)

        // Test stage 3 dependencies
        let stage3Deps = GraphTraversal.findStageDependencies(of: stage3, in: graph)
        #expect(stage3Deps.contains("build"))  // From index(0)
        #expect(stage3Deps.contains("test"))  // From .previous
        #expect(stage3Deps.count == 2)

        // Test stage 1 dependencies (should be empty)
        let stage1Deps = GraphTraversal.findStageDependencies(of: stage1, in: graph)
        #expect(stage1Deps.isEmpty)
    }

    // MARK: - Build Graph Analysis Tests

    @Test func buildGraphAnalysis() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let graph = try GraphBuilder.multiStage { builder in
            try builder
                .stage(name: "build", from: alpineRef)
                .run("apk add --no-cache build-tools")
                .workdir("/src")
                .copyFromContext(paths: ["src/"], to: "./")
                .run("make build")

            try builder
                .stage(name: "test", from: alpineRef)
                .copyFromStage(.named("build"), paths: ["/src/app"], to: "/test/")
                .run("./test/app --test")

            try builder
                .stage(from: alpineRef)
                .copyFromStage(.named("build"), paths: ["/src/app"], to: "/usr/local/bin/")
                .entrypoint(.exec(["/usr/local/bin/app"]))
        }

        let analysis = graph.analyze()

        #expect(analysis.stageCount == 3)
        #expect(analysis.operationCount > 0)

        // Verify operation types are counted
        #expect(analysis.operationsByType[OperationKind.exec] != nil)
        #expect(analysis.operationsByType[OperationKind.filesystem] != nil)
        #expect(analysis.operationsByType[OperationKind.metadata] != nil)

        // Verify stage dependencies
        #expect(analysis.stageDependencies["test"]?.contains("build") == true)
        #expect(analysis.stageDependencies.count >= 1)

        #expect(analysis.maxDepth > 0)
        #expect(analysis.criticalPathLength > 0)
    }

    // MARK: - Error Handling Tests

    @Test func invalidStageReferenceHandling() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create stage with invalid reference
        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .stage(.named("nonexistent"), paths: ["/file"]),
                        destination: "/test/file"
                    ),
                    dependencies: []
                )
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let analyzer = DependencyAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)

        // Should not throw - dependency analyzer handles missing references gracefully
        let analyzedGraph = try analyzer.analyze(graph, context: context)

        // The copy operation should not have gained any cross-stage dependencies
        let copyNode = analyzedGraph.stages[0].nodes[0]
        #expect(
            copyNode.dependencies.isEmpty,
            "Copy from nonexistent stage should not create dependencies")
    }

    @Test func complexDependencyChain() throws {
        // Test a complex multi-stage build with intricate dependencies
        guard let nodeRef = ImageReference(parsing: "node:18"),
            let nginxRef = ImageReference(parsing: "nginx:alpine")
        else {
            Issue.record("Failed to parse image references")
            return
        }

        let graph = try GraphBuilder.multiStage { builder in
            // Dependencies stage
            try builder
                .stage(name: "deps", from: nodeRef)
                .workdir("/app")
                .copyFromContext(paths: ["package*.json"], to: "./")
                .run("npm ci --only=production")

            // Build stage
            try builder
                .stage(name: "build", from: nodeRef)
                .workdir("/app")
                .copyFromStage(.named("deps"), paths: ["/app/node_modules"], to: "/app/node_modules")
                .copyFromContext(paths: ["src/", "tsconfig.json"], to: "./")
                .run("npm run build")

            // Assets stage
            try builder
                .stage(name: "assets", from: nodeRef)
                .workdir("/app")
                .copyFromStage(.named("build"), paths: ["/app/dist"], to: "/app/dist")
                .run("npm run optimize-assets")

            // Final stage
            try builder
                .stage(from: nginxRef)
                .copyFromStage(.named("assets"), paths: ["/app/dist"], to: "/usr/share/nginx/html")
                .copyFromContext(paths: ["nginx.conf"], to: "/etc/nginx/nginx.conf")
                .expose(80)
        }

        let analyzer = DependencyAnalyzer()
        let context = AnalysisContext(reporter: nil, sourceMap: nil)
        let analyzedGraph = try analyzer.analyze(graph, context: context)

        // Verify complex dependency chain
        let finalStage = analyzedGraph.stages[3]
        let copyFromAssetsNode = finalStage.nodes[0]
        let assetsStageLastNode = analyzedGraph.stages[2].nodes.last!

        #expect(copyFromAssetsNode.dependencies.contains(assetsStageLastNode.id))

        // Verify transitive dependencies exist through the chain
        let assetsStage = analyzedGraph.stages[2]
        let copyFromBuildNode = assetsStage.nodes[1]  // Node 1 is the copyFromStage operation
        let buildStageLastNode = analyzedGraph.stages[1].nodes.last!

        #expect(copyFromBuildNode.dependencies.contains(buildStageLastNode.id))

        // Verify build stage dependencies
        let buildStage = analyzedGraph.stages[1]
        let copyFromDepsNode = buildStage.nodes[1]  // Node 1 is the copyFromStage operation
        let depsStageLastNode = analyzedGraph.stages[0].nodes.last!

        #expect(copyFromDepsNode.dependencies.contains(depsStageLastNode.id))
    }
}
