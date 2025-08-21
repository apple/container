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

import ContainerBuildExecutor
import ContainerBuildIR
import ContainerBuildReporting
import Foundation

/// Visualizes build graphs in various formats
public struct GraphVisualizer {

    // MARK: - ASCII Visualization

    /// Generate an ASCII representation of the build graph
    public static func generateASCII(_ graph: BuildGraph) -> String {
        var output = ""
        let analysis = graph.analyze()

        // Header
        output += "Build Graph\n"
        output += "===========\n"
        output += "Stages: \(analysis.stageCount) | Operations: \(analysis.operationCount) | Critical Path: \(analysis.criticalPathLength)\n"
        output += "\n"

        // Process each stage and collect cross-stage dependencies
        var crossStageDeps: [(from: String, to: String, desc: String)] = []

        for (stageIndex, stage) in graph.stages.enumerated() {
            let stageName = stage.name ?? "stage-\(stageIndex)"
            output += drawStage(stage, name: stageName, in: graph)

            // Check for cross-stage dependencies
            for node in stage.nodes {
                if let fsOp = node.operation as? FilesystemOperation {
                    switch fsOp.source {
                    case .stage(let ref, let paths):
                        let sourceStage: String
                        switch ref {
                        case .named(let name):
                            sourceStage = name
                        case .index(let idx):
                            sourceStage = "stage-\(idx)"
                        case .previous:
                            sourceStage = stageIndex > 0 ? (graph.stages[stageIndex - 1].name ?? "stage-\(stageIndex-1)") : "unknown"
                        }
                        crossStageDeps.append((from: sourceStage, to: stageName, desc: "COPY \(paths.first ?? "")"))
                    default:
                        break
                    }
                }
            }

            output += "\n"
        }

        // Show cross-stage dependencies
        if !crossStageDeps.isEmpty {
            output += "Cross-Stage Dependencies:\n"
            for dep in crossStageDeps {
                output += "  \(dep.from) → \(dep.to) [\(dep.desc)]\n"
            }
            output += "\n"
        }

        // Parallelism analysis
        let parallelGroups = analysis.parallelismOpportunities.filter { $0.count > 1 }
        if !parallelGroups.isEmpty {
            output += "Parallelism Analysis\n"
            output += "===================\n"
            for (index, group) in parallelGroups.enumerated() {
                output += "Group \(index + 1): \(group.count) operations can run in parallel\n"
            }
        }

        return output
    }

    private static func drawStage(_ stage: BuildStage, name: String, in graph: BuildGraph) -> String {
        var output = ""

        // Stage header
        let headerLine = "┌─ Stage: \(name) "
        output += headerLine + String(repeating: "─", count: max(50 - headerLine.count, 3)) + "┐\n"

        // First draw the base image operation
        let baseDesc = formatNodeDescription(BuildNode(operation: stage.base))
        output += "│  [\(baseDesc)]\n"

        // Draw nodes in order
        for (_, node) in stage.nodes.enumerated() {
            output += "│\n"
            output += "│  ↓\n"
            output += drawNodesAtLevel([node], in: stage, showParallel: false)
        }

        // Stage footer
        output += "└" + String(repeating: "─", count: 51) + "┘\n"

        return output
    }

    private static func computeNodeLevels(_ nodes: [BuildNode]) -> [[BuildNode]] {
        var levels: [[BuildNode]] = []
        var nodeLevel: [UUID: Int] = [:]

        func computeLevel(for node: BuildNode) -> Int {
            if let level = nodeLevel[node.id] {
                return level
            }

            var maxDepLevel = -1
            for depId in node.dependencies {
                if let depNode = nodes.first(where: { $0.id == depId }) {
                    maxDepLevel = max(maxDepLevel, computeLevel(for: depNode))
                }
            }

            let level = maxDepLevel + 1
            nodeLevel[node.id] = level
            return level
        }

        // Compute level for each node
        for node in nodes {
            let level = computeLevel(for: node)
            while levels.count <= level {
                levels.append([])
            }
            levels[level].append(node)
        }

        return levels
    }

    private static func drawConnections(from previousNodes: [BuildNode], to currentNodes: [BuildNode], in stage: BuildStage) -> String {
        var output = "│\n"

        // Check if any connections exist
        var hasConnections = false
        for node in currentNodes {
            if !node.dependencies.isEmpty {
                hasConnections = true
                break
            }
        }

        if hasConnections {
            // Draw connection lines
            var connectionLine = "│  "
            for (index, node) in currentNodes.enumerated() {
                if index > 0 {
                    connectionLine += "     "
                }

                let depCount = node.dependencies.count
                if depCount > 0 {
                    connectionLine += "╱"
                    if depCount > 1 {
                        connectionLine += "─┴─"
                    } else {
                        connectionLine += "───"
                    }
                    connectionLine += "╲"
                } else {
                    connectionLine += "     "
                }
            }
            output += connectionLine + "\n"
        }

        return output
    }

    private static func drawNodesAtLevel(_ nodes: [BuildNode], in stage: BuildStage, showParallel: Bool) -> String {
        var output = "│  "

        // Draw nodes
        for (index, node) in nodes.enumerated() {
            if index > 0 {
                output += "  "
                if showParallel {
                    output += "║  "  // Double bar indicates parallel execution
                } else {
                    output += "   "
                }
            }

            let desc = formatNodeDescription(node)
            output += "[\(desc)]"
        }

        output += "\n"
        return output
    }

    private static func formatNodeDescription(_ node: BuildNode) -> String {
        let fullDesc = ReportContext.describeOperation(node.operation)
        let parts = fullDesc.split(separator: " ", maxSplits: 1)
        let operation = String(parts[0])
        let args = parts.count > 1 ? String(parts[1]) : ""

        // Format based on operation type
        switch operation {
        case "FROM":
            return "FROM \(truncate(args, to: 20))"
        case "RUN":
            return "RUN \(truncate(args, to: 25))"
        case "COPY", "ADD":
            let paths = args.split(separator: " ")
            let source = paths.first ?? ""
            return "\(operation) \(truncate(String(source), to: 15))"
        case "WORKDIR":
            return "WORKDIR \(args)"
        case "ENV":
            return "ENV \(truncate(args, to: 20))"
        case "EXPOSE":
            return "EXPOSE \(args)"
        case "CMD", "ENTRYPOINT":
            return "\(operation) \(truncate(args, to: 18))"
        case "LABEL":
            return "LABEL \(truncate(args, to: 18))"
        case "USER":
            return "USER \(args)"
        case "ARG":
            return "ARG \(truncate(args, to: 20))"
        case "VOLUME":
            return "VOLUME \(args)"
        default:
            return "\(operation) \(truncate(args, to: 18))"
        }
    }

    private static func truncate(_ string: String, to length: Int) -> String {
        if string.count <= length {
            return string
        }
        return String(string.prefix(length - 3)) + "..."
    }

    // MARK: - Graphviz DOT Format

    /// Generate a Graphviz DOT representation of the build graph
    public static func generateDOT(_ graph: BuildGraph) -> String {
        var output = "digraph BuildGraph {\n"
        output += "  rankdir=TB;\n"
        output += "  node [shape=box, style=rounded];\n"
        output += "  \n"

        // Graph metadata
        output += "  label=\"Build Graph - \(graph.stages.count) stages, \(graph.targetPlatforms.count) platforms\";\n"
        output += "  labelloc=t;\n"
        output += "  \n"

        // Process each stage
        for (stageIndex, stage) in graph.stages.enumerated() {
            let stageName = stage.name ?? "stage_\(stageIndex)"

            // Create subgraph for stage
            output += "  subgraph cluster_\(stageIndex) {\n"
            output += "    label=\"Stage: \(stageName)\";\n"
            output += "    style=dotted;\n"
            output += "    color=gray;\n"
            output += "    \n"

            // Add nodes
            for node in stage.nodes {
                let nodeId = sanitizeNodeId(node.id.uuidString)
                let label = formatNodeLabel(node)
                let color = getNodeColor(for: node.operation)

                output += "    \(nodeId) [label=\"\(label)\", fillcolor=\"\(color)\", style=filled];\n"
            }

            // Add dependencies within stage
            for node in stage.nodes {
                let nodeId = sanitizeNodeId(node.id.uuidString)
                for depId in node.dependencies {
                    let depNodeId = sanitizeNodeId(depId.uuidString)
                    output += "    \(depNodeId) -> \(nodeId);\n"
                }
            }

            output += "  }\n"
            output += "  \n"
        }

        // Add cross-stage dependencies
        output += "  // Cross-stage dependencies\n"
        for (stageIndex, stage) in graph.stages.enumerated() {
            for node in stage.nodes {
                if let fsOp = node.operation as? FilesystemOperation {
                    switch fsOp.source {
                    case .stage(let ref, _):
                        if let sourceStage = graph.resolveStage(ref),
                            let sourceIndex = graph.stages.firstIndex(where: { $0.id == sourceStage.id }),
                            sourceIndex != stageIndex
                        {
                            // Draw edge from last node of source stage to this node
                            if let lastNode = sourceStage.nodes.last {
                                let sourceId = sanitizeNodeId(lastNode.id.uuidString)
                                let targetId = sanitizeNodeId(node.id.uuidString)
                                output += "  \(sourceId) -> \(targetId) [style=dashed, color=blue, label=\"stage copy\"];\n"
                            }
                        }
                    default:
                        break
                    }
                }
            }
        }

        output += "}\n"
        return output
    }

    private static func sanitizeNodeId(_ id: String) -> String {
        "node_" + id.replacingOccurrences(of: "-", with: "_")
    }

    private static func formatNodeLabel(_ node: BuildNode) -> String {
        let desc = ReportContext.describeOperation(node.operation)
        let parts = desc.split(separator: " ", maxSplits: 1)
        let operation = String(parts[0])
        let args = parts.count > 1 ? String(parts[1]) : ""

        // Escape quotes for DOT format
        let escapedArgs =
            args
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        switch operation {
        case "RUN", "COPY", "ADD", "CMD", "ENTRYPOINT":
            return "\(operation)\\n\(truncate(escapedArgs, to: 30))"
        default:
            return "\(operation)\\n\(escapedArgs)"
        }
    }

    private static func getNodeColor(for operation: any ContainerBuildIR.Operation) -> String {
        switch operation {
        case is ImageOperation:
            return "#E8F5E9"  // Light green
        case is ExecOperation:
            return "#E3F2FD"  // Light blue
        case is FilesystemOperation:
            return "#FFF3E0"  // Light orange
        case is MetadataOperation:
            return "#F3E5F5"  // Light purple
        default:
            return "#F5F5F5"  // Light gray
        }
    }

    // MARK: - Mermaid Format

    /// Generate a Mermaid diagram representation of the build graph
    public static func generateMermaid(_ graph: BuildGraph) -> String {
        var output = "graph TB\n"

        // Process each stage
        for (stageIndex, stage) in graph.stages.enumerated() {
            let stageName = stage.name ?? "stage-\(stageIndex)"

            // Add stage label
            output += "  subgraph \(stageName)\n"

            // Add nodes
            for node in stage.nodes {
                let nodeId = "N" + node.id.uuidString.prefix(8)
                let label = formatNodeDescription(node)
                output += "    \(nodeId)[\"\(label)\"]\n"
            }

            // Add dependencies
            for node in stage.nodes {
                let nodeId = "N" + node.id.uuidString.prefix(8)
                for depId in node.dependencies {
                    let depNodeId = "N" + depId.uuidString.prefix(8)
                    output += "    \(depNodeId) --> \(nodeId)\n"
                }
            }

            output += "  end\n"
        }

        return output
    }
}

// MARK: - Convenience Extensions

extension BuildGraph {
    /// Generate ASCII visualization of this graph
    public var asciiDiagram: String {
        GraphVisualizer.generateASCII(self)
    }

    /// Generate Graphviz DOT format of this graph
    public var dotFormat: String {
        GraphVisualizer.generateDOT(self)
    }

    /// Generate Mermaid diagram of this graph
    public var mermaidDiagram: String {
        GraphVisualizer.generateMermaid(self)
    }
}
