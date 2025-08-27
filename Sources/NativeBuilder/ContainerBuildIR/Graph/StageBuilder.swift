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
import ContainerizationOCI
import Foundation

/// Builder for individual stages.
final class StageBuilder {
    let name: String?
    let base: ImageOperation
    let platform: Platform?
    private var nodes: [BuildNode] = []
    private var lastNodeId: UUID?
    private let analyzers: [any StageAnalyzer]
    private let reporter: Reporter?

    init(name: String?, base: ImageOperation, platform: Platform? = nil, analyzers: [any StageAnalyzer] = [], reporter: Reporter? = nil) {
        self.name = name
        self.base = base
        self.platform = platform
        self.analyzers = analyzers
        self.reporter = reporter
    }

    @discardableResult
    func add(_ operation: any Operation, dependsOn: Set<UUID> = []) -> UUID {
        let node = BuildNode(
            operation: operation,
            dependencies: dependsOn
        )

        // Report node addition
        if let reporter = reporter {
            let stageId = name ?? "stage-\(node.id.uuidString.prefix(8))"
            Task {
                await reporter.report(
                    .irEvent(
                        context: ReportContext(
                            nodeId: node.id,
                            stageId: stageId,
                            description: "Added \(type(of: operation))",
                            sourceMap: nil
                        ),
                        type: .nodeAdded
                    ))
            }
        }

        nodes.append(node)
        lastNodeId = node.id
        return node.id
    }

    func getDeclaredArg(_ name: String) -> (found: Bool, defaultValue: String?) {
        for node in nodes {
            if let metadataOp = node.operation as? MetadataOperation, case .declareArg(let argName, let defaultValue) = metadataOp.action, argName == name {
                return (found: true, defaultValue: defaultValue)
            }
        }
        return (found: false, defaultValue: nil)
    }

    func build() throws -> BuildStage {
        var stage = BuildStage(
            name: name,
            base: base,
            nodes: nodes,
            platform: platform
        )

        // Create analysis context
        let analysisContext = AnalysisContext(reporter: reporter)

        // Run stage analyzers
        for analyzer in analyzers {
            stage = try analyzer.analyze(stage, context: analysisContext)
        }

        return stage
    }
}
