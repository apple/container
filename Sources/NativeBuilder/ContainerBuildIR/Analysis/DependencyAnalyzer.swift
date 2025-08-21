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

import ContainerBuildReporting
import Foundation

/// Establishes dependencies between operations in the build graph.
///
/// This analyzer is responsible for:
/// - Setting up intra-stage dependencies (sequential operations within a stage)
/// - Establishing cross-stage dependencies (COPY --from operations)
/// - Ensuring operations have proper dependencies for correct execution order
public struct DependencyAnalyzer: GraphAnalyzer {

    public init() {}

    public func analyze(_ graph: BuildGraph, context: AnalysisContext) throws -> BuildGraph {
        var updatedStages: [BuildStage] = []

        // Process each stage
        for stage in graph.stages {
            let updatedStage = try analyzeStage(stage, allStages: graph.stages)
            updatedStages.append(updatedStage)
        }

        // Create updated graph with new dependencies
        return try BuildGraph(
            stages: updatedStages,
            buildArgs: graph.buildArgs,
            targetPlatforms: graph.targetPlatforms,
            metadata: graph.metadata
        )
    }

    private func analyzeStage(_ stage: BuildStage, allStages: [BuildStage]) throws -> BuildStage {
        var updatedNodes: [BuildNode] = []
        var lastNodeId: UUID? = nil

        // Process each node in the stage
        for (index, node) in stage.nodes.enumerated() {
            var dependencies = node.dependencies

            // 1. Sequential dependency: each operation depends on the previous one
            if dependencies.isEmpty && index > 0 {
                if let lastId = lastNodeId {
                    dependencies.insert(lastId)
                }
            }

            // 2. Cross-stage dependencies: COPY --from operations
            if let copyOp = node.operation as? FilesystemOperation {
                if case .stage(let stageRef, _) = copyOp.source {
                    // Find the referenced stage
                    if let sourceStage = resolveStageReference(stageRef, currentStage: stage, allStages: allStages) {
                        // COPY --from depends on all operations in the source stage
                        if let lastOp = sourceStage.nodes.last {
                            dependencies.insert(lastOp.id)
                        }
                    }
                }
            }

            // Create updated node with dependencies
            let updatedNode = BuildNode(
                id: node.id,
                operation: node.operation,
                dependencies: dependencies
            )

            updatedNodes.append(updatedNode)
            lastNodeId = updatedNode.id
        }

        // Return updated stage
        return BuildStage(
            id: stage.id,
            name: stage.name,
            base: stage.base,
            nodes: updatedNodes,
            platform: stage.platform
        )
    }

    private func resolveStageReference(_ ref: StageReference, currentStage: BuildStage, allStages: [BuildStage]) -> BuildStage? {
        switch ref {
        case .named(let name):
            return allStages.first { $0.name == name }
        case .index(let idx):
            return idx < allStages.count ? allStages[idx] : nil
        case .previous:
            // Find current stage index
            if let currentIndex = allStages.firstIndex(where: { $0.id == currentStage.id }), currentIndex > 0 {
                return allStages[currentIndex - 1]
            }
            return nil
        }
    }
}
