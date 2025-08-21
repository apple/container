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

/// Context provided to analyzers during analysis
public struct AnalysisContext: Sendable {
    /// Reporter for emitting warnings, errors, and other events
    public let reporter: Reporter?

    /// Source location information if available
    public let sourceMap: SourceMap?

    public init(reporter: Reporter? = nil, sourceMap: SourceMap? = nil) {
        self.reporter = reporter
        self.sourceMap = sourceMap
    }
}

/// Stage-level analyzer that can transform stages
public protocol StageAnalyzer {
    /// Analyze and potentially transform a single stage
    func analyze(_ stage: BuildStage, context: AnalysisContext) throws -> BuildStage
}

/// Graph-level analyzer that can transform the entire build graph
public protocol GraphAnalyzer {
    /// Analyze and potentially transform the entire build graph
    func analyze(_ graph: BuildGraph, context: AnalysisContext) throws -> BuildGraph
}
