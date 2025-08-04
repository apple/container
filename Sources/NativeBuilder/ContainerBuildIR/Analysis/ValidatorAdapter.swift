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

/// Adapts a BuildValidator to work as a GraphAnalyzer
public struct ValidatorAnalyzer: GraphAnalyzer {
    private let validator: any BuildValidator & Sendable

    public init<V: BuildValidator & Sendable>(validator: V) {
        self.validator = validator
    }

    public func analyze(_ graph: BuildGraph, context: AnalysisContext) throws -> BuildGraph {
        let result = validator.validate(graph)

        // Report errors via reporter
        if let reporter = context.reporter {
            let sourceMap = context.sourceMap
            for error in result.errors {
                let description = error.localizedDescription
                Task {
                    await reporter.report(
                        .irEvent(
                            context: ReportContext(
                                description: description,
                                sourceMap: sourceMap
                            ),
                            type: .error
                        ))
                }
            }
        }

        // Report warnings via reporter
        if let reporter = context.reporter {
            let sourceMap = context.sourceMap
            for warning in result.warnings {
                let message = warning.suggestion != nil ? "\(warning.message). \(warning.suggestion!)" : warning.message

                Task {
                    await reporter.report(
                        .irEvent(
                            context: ReportContext(
                                description: message,
                                sourceMap: sourceMap
                            ),
                            type: .warning
                        ))
                }
            }
        }

        // Always fail on error as requested
        if !result.errors.isEmpty {
            throw result.errors.first!
        }

        // Validation doesn't transform the graph
        return graph
    }
}
