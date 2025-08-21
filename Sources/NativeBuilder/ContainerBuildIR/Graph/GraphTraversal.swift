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

/// Utilities for traversing and analyzing build graphs.
///
/// Design rationale:
/// - Provides common graph algorithms (topological sort, dependency analysis)
/// - Supports both forward and reverse traversal
/// - Enables optimization passes and validation
public enum GraphTraversal {

    /// Perform topological sort on nodes in a stage.
    ///
    /// - Returns: Nodes in execution order
    /// - Throws: If graph contains cycles
    public static func topologicalSort(_ stage: BuildStage) throws -> [BuildNode] {
        var sorted: [BuildNode] = []
        var visited = Set<UUID>()
        var visiting = Set<UUID>()

        func visit(_ nodeId: UUID) throws {
            if visiting.contains(nodeId) {
                throw BuildGraphError.cyclicDependency
            }

            if visited.contains(nodeId) {
                return
            }

            guard let node = stage.nodes.first(where: { $0.id == nodeId }) else {
                return
            }

            visiting.insert(nodeId)

            for dep in node.dependencies {
                try visit(dep)
            }

            visiting.remove(nodeId)
            visited.insert(nodeId)
            sorted.append(node)
        }

        for node in stage.nodes {
            try visit(node.id)
        }

        return sorted
    }

    /// Find all nodes that depend on a given node.
    public static func findDependents(
        of nodeId: UUID,
        in stage: BuildStage
    ) -> Set<UUID> {
        var dependents = Set<UUID>()

        for node in stage.nodes {
            if node.dependencies.contains(nodeId) {
                dependents.insert(node.id)
                // Recursively find transitive dependents
                let transitive = findDependents(of: node.id, in: stage)
                dependents.formUnion(transitive)
            }
        }

        return dependents
    }

    /// Find all nodes that a given node depends on.
    public static func findDependencies(
        of nodeId: UUID,
        in stage: BuildStage
    ) -> Set<UUID> {
        guard let node = stage.nodes.first(where: { $0.id == nodeId }) else {
            return []
        }

        var allDeps = node.dependencies

        for dep in node.dependencies {
            let transitive = findDependencies(of: dep, in: stage)
            allDeps.formUnion(transitive)
        }

        return allDeps
    }

    /// Find stages that a given stage depends on.
    public static func findStageDependencies(
        of stage: BuildStage,
        in graph: BuildGraph
    ) -> Set<String> {
        var stageDeps = Set<String>()

        for dep in stage.stageDependencies() {
            switch dep {
            case .named(let name):
                stageDeps.insert(name)
            case .index(let idx):
                if let depStage = graph.stage(at: idx),
                    let name = depStage.name
                {
                    stageDeps.insert(name)
                }
            case .previous:
                if let stageIndex = graph.stages.firstIndex(where: { $0.id == stage.id }),
                    stageIndex > 0,
                    let prevName = graph.stages[stageIndex - 1].name
                {
                    stageDeps.insert(prevName)
                }
            }
        }

        return stageDeps
    }

    /// Perform a depth-first traversal of the graph.
    public static func depthFirst(
        stage: BuildStage,
        visit: (BuildNode) throws -> Void
    ) throws {
        var visited = Set<UUID>()

        func dfs(_ nodeId: UUID) throws {
            guard !visited.contains(nodeId) else { return }
            visited.insert(nodeId)

            guard let node = stage.nodes.first(where: { $0.id == nodeId }) else {
                return
            }

            // Visit dependencies first
            for dep in node.dependencies {
                try dfs(dep)
            }

            try visit(node)
        }

        // Visit all nodes, starting from roots but ensuring all nodes are visited
        for node in stage.nodes {
            try dfs(node.id)
        }
    }

    /// Find root nodes (nodes with no dependencies).
    public static func findRoots(in stage: BuildStage) -> [BuildNode] {
        stage.nodes.filter { $0.dependencies.isEmpty }
    }

    /// Find leaf nodes (nodes with no dependents).
    public static func findLeaves(in stage: BuildStage) -> [BuildNode] {
        stage.nodes.filter { node in
            !stage.nodes.contains { $0.dependencies.contains(node.id) }
        }
    }

    /// Calculate the critical path (longest path) through the graph.
    public static func criticalPath(in stage: BuildStage) -> [BuildNode] {
        // This is a simplified version - real implementation would
        // consider execution times
        var pathLengths = [UUID: Int]()
        var nextInPath = [UUID: UUID?]()

        // Initialize all nodes
        for node in stage.nodes {
            pathLengths[node.id] = 1
            nextInPath[node.id] = nil
        }

        // Calculate longest paths
        if let sorted = try? topologicalSort(stage) {
            for node in sorted.reversed() {
                for dep in node.dependencies {
                    guard let nodeLength = pathLengths[node.id],
                        let depLength = pathLengths[dep]
                    else {
                        continue
                    }

                    let newLength = nodeLength + 1
                    if newLength > depLength {
                        pathLengths[dep] = newLength
                        nextInPath[dep] = node.id
                    }
                }
            }
        }

        // Find the starting node with longest path
        let start = pathLengths.max(by: { $0.value < $1.value })?.key

        // Build the path
        var path: [BuildNode] = []
        var current = start

        while let nodeId = current,
            let node = stage.nodes.first(where: { $0.id == nodeId })
        {
            path.append(node)
            current = nextInPath[nodeId] ?? nil
        }

        return path
    }
}

/// Graph analysis results.
public struct GraphAnalysis {
    /// Total number of operations
    public let operationCount: Int

    /// Operations by type
    public let operationsByType: [OperationKind: Int]

    /// Number of stages
    public let stageCount: Int

    /// Stage dependencies
    public let stageDependencies: [String: Set<String>]

    /// Maximum depth of the graph
    public let maxDepth: Int

    /// Critical path length
    public let criticalPathLength: Int

    /// Parallelism opportunities (nodes that can run concurrently)
    public let parallelismOpportunities: [[UUID]]
}

extension BuildGraph {
    /// Analyze the build graph structure.
    public func analyze() -> GraphAnalysis {
        var operationsByType = [OperationKind: Int]()
        var stageDeps = [String: Set<String>]()
        var maxDepth = 0
        var criticalLength = 0

        // Count operations and analyze stages
        for stage in stages {
            if let name = stage.name {
                stageDeps[name] = GraphTraversal.findStageDependencies(of: stage, in: self)
            }

            for op in stage.operations {
                operationsByType[op.operationKind, default: 0] += 1
            }

            // Calculate depth
            if let sorted = try? GraphTraversal.topologicalSort(stage) {
                maxDepth = max(maxDepth, sorted.count)
            }

            // Critical path
            let critical = GraphTraversal.criticalPath(in: stage)
            criticalLength = max(criticalLength, critical.count)
        }

        return GraphAnalysis(
            operationCount: stages.flatMap { $0.operations }.count,
            operationsByType: operationsByType,
            stageCount: stages.count,
            stageDependencies: stageDeps,
            maxDepth: maxDepth,
            criticalPathLength: criticalLength,
            parallelismOpportunities: []  // TODO: Implement
        )
    }
}
