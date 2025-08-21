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

/// Performs semantic analysis on build graphs.
///
/// Design rationale:
/// - Goes beyond structural validation to understand intent
/// - Provides optimization suggestions
/// - Detects common patterns and anti-patterns
public struct SemanticAnalyzer: GraphAnalyzer {

    /// Initialize a new semantic analyzer.
    public init() {}

    /// Analyze a build graph and report issues via the reporter
    public func analyze(_ graph: BuildGraph, context: AnalysisContext) throws -> BuildGraph {
        // Perform the analysis
        let analysis = performAnalysis(graph)

        // Report findings via the reporter
        reportFindings(analysis, context: context)

        // Return the graph unchanged (semantic analyzer doesn't transform)
        return graph
    }

    /// Perform semantic analysis on the graph
    private func performAnalysis(_ graph: BuildGraph) -> SemanticAnalysis {
        let layerAnalysis = analyzeLayerEfficiency(graph)
        let cacheAnalysis = analyzeCacheability(graph)
        let securityAnalysis = analyzeSecurityPosture(graph)
        let sizeAnalysis = analyzeSizeOptimizations(graph)

        return SemanticAnalysis(
            layerEfficiency: layerAnalysis,
            cacheability: cacheAnalysis,
            security: securityAnalysis,
            sizeOptimizations: sizeAnalysis
        )
    }

    // MARK: - Layer Efficiency

    private func analyzeLayerEfficiency(_ graph: BuildGraph) -> LayerEfficiencyAnalysis {
        var issues: [LayerIssue] = []

        for stage in graph.stages {
            // Check for operations that could be combined
            let _ = stage.nodes.compactMap { $0.operation as? ExecOperation }

            // Detect multiple package manager invocations
            var packageManagerCalls: [(command: String, node: BuildNode)] = []

            for (_, node) in stage.nodes.enumerated() {
                if let execOp = node.operation as? ExecOperation,
                    case .shell(let cmd) = execOp.command
                {
                    if cmd.contains("apt-get") || cmd.contains("yum") || cmd.contains("apk") || cmd.contains("dnf") {
                        packageManagerCalls.append((cmd, node))
                    }
                }
            }

            if packageManagerCalls.count > 1 {
                issues.append(
                    LayerIssue(
                        type: .multipleLayers,
                        description: "Multiple package manager invocations create separate layers",
                        suggestion: "Combine package installations into a single RUN command",
                        estimatedImpact: .high
                    ))
            }

            // Check for file operations followed by deletions
            for (index, node) in stage.nodes.enumerated() {
                if let fsOp = node.operation as? FilesystemOperation,
                    fsOp.action == .copy || fsOp.action == .add
                {
                    // Look for subsequent removal
                    for nextNode in stage.nodes[(index + 1)...] {
                        if let nextFs = nextNode.operation as? FilesystemOperation,
                            nextFs.action == .remove
                        {
                            issues.append(
                                LayerIssue(
                                    type: .unnecessaryFiles,
                                    description: "Files added then removed still consume layer space",
                                    suggestion: "Avoid adding files that will be deleted",
                                    estimatedImpact: .medium
                                ))
                        }
                    }
                }
            }
        }

        return LayerEfficiencyAnalysis(issues: issues)
    }

    // MARK: - Cache Analysis

    private func analyzeCacheability(_ graph: BuildGraph) -> CacheabilityAnalysis {
        var invalidators: [CacheInvalidator] = []

        for stage in graph.stages {
            // Check for operations that frequently invalidate cache
            for (index, node) in stage.nodes.enumerated() {
                if let fsOp = node.operation as? FilesystemOperation {
                    switch fsOp.source {
                    case .context(let source):
                        // Copying entire context early invalidates cache
                        if source.paths.contains(".") && index < stage.nodes.count / 2 {
                            invalidators.append(
                                CacheInvalidator(
                                    operation: "COPY . .",
                                    reason: "Copying entire context early in build",
                                    suggestion: "Copy only necessary files or move COPY . . later"
                                ))
                        }
                    default:
                        break
                    }
                }

                // Dynamic commands that change frequently
                if let execOp = node.operation as? ExecOperation,
                    case .shell(let cmd) = execOp.command
                {
                    if cmd.contains("date") || cmd.contains("timestamp") || cmd.contains("git rev-parse") {
                        invalidators.append(
                            CacheInvalidator(
                                operation: cmd,
                                reason: "Command output changes frequently",
                                suggestion: "Use build args for dynamic values"
                            ))
                    }
                }
            }
        }

        return CacheabilityAnalysis(
            cacheInvalidators: invalidators,
            estimatedCacheHitRate: invalidators.isEmpty ? 0.8 : 0.3
        )
    }

    // MARK: - Security Analysis

    private func analyzeSecurityPosture(_ graph: BuildGraph) -> SecurityAnalysis {
        var findings: [SecurityFinding] = []

        for stage in graph.stages {
            var currentUser: User?
            var hasUserSwitch = false

            for node in stage.nodes {
                // Track user context
                if let metaOp = node.operation as? MetadataOperation,
                    case .setUser(let user) = metaOp.action
                {
                    currentUser = user
                    hasUserSwitch = true
                }

                // Check for security issues in exec operations
                if let execOp = node.operation as? ExecOperation {
                    // Running privileged without user switch
                    if execOp.security.privileged && !hasUserSwitch {
                        findings.append(
                            SecurityFinding(
                                severity: .high,
                                type: .privilegedExecution,
                                description: "Privileged execution as root",
                                remediation: "Switch to non-root user after privileged operations"
                            ))
                    }

                    // Downloading without verification
                    if case .shell(let cmd) = execOp.command {
                        if (cmd.contains("curl") || cmd.contains("wget")) && !cmd.contains("--verify") && !cmd.contains("sha256") {
                            findings.append(
                                SecurityFinding(
                                    severity: .medium,
                                    type: .unverifiedDownload,
                                    description: "Downloading files without verification",
                                    remediation: "Add checksum verification for downloaded files"
                                ))
                        }

                        // Installing packages without pinning versions
                        if cmd.contains("install") && !cmd.contains("=") && (cmd.contains("apt-get") || cmd.contains("pip")) {
                            findings.append(
                                SecurityFinding(
                                    severity: .low,
                                    type: .unpinnedDependencies,
                                    description: "Installing packages without version pinning",
                                    remediation: "Pin package versions for reproducible builds"
                                ))
                        }
                    }
                }
            }

            // Final user check
            if currentUser == nil && stage == graph.targetStage {
                findings.append(
                    SecurityFinding(
                        severity: .high,
                        type: .rootUser,
                        description: "Container runs as root by default",
                        remediation: "Add USER instruction to run as non-root"
                    ))
            }
        }

        return SecurityAnalysis(findings: findings)
    }

    // MARK: - Size Optimization

    private func analyzeSizeOptimizations(_ graph: BuildGraph) -> SizeOptimizationAnalysis {
        var opportunities: [SizeOptimization] = []

        for stage in graph.stages {
            var hasCleanup = false

            for node in stage.nodes {
                if let execOp = node.operation as? ExecOperation,
                    case .shell(let cmd) = execOp.command
                {
                    // Check for package manager cleanup
                    if cmd.contains("apt-get install") && !cmd.contains("rm -rf /var/lib/apt/lists/*") {
                        opportunities.append(
                            SizeOptimization(
                                type: .packageManagerCache,
                                description: "Package manager cache not cleaned",
                                estimatedSavingMB: 50,
                                suggestion: "Add && rm -rf /var/lib/apt/lists/* after apt-get install"
                            ))
                    }

                    // Check for build dependencies
                    if cmd.contains("build-essential") || cmd.contains("-dev") {
                        let isMultiStage = graph.stages.count > 1
                        if !isMultiStage {
                            opportunities.append(
                                SizeOptimization(
                                    type: .buildDependencies,
                                    description: "Build dependencies included in final image",
                                    estimatedSavingMB: 200,
                                    suggestion: "Use multi-stage build to exclude build dependencies"
                                ))
                        }
                    }

                    if cmd.contains("rm") || cmd.contains("clean") {
                        hasCleanup = true
                    }
                }
            }

            // Check for cleanup in separate layers
            if hasCleanup {
                opportunities.append(
                    SizeOptimization(
                        type: .separateCleanupLayer,
                        description: "Cleanup in separate RUN creates new layer",
                        estimatedSavingMB: 0,
                        suggestion: "Combine cleanup with installation in same RUN"
                    ))
            }
        }

        return SizeOptimizationAnalysis(opportunities: opportunities)
    }
}

// MARK: - Analysis Results

/// Complete semantic analysis results.
public struct SemanticAnalysis {
    public let layerEfficiency: LayerEfficiencyAnalysis
    public let cacheability: CacheabilityAnalysis
    public let security: SecurityAnalysis
    public let sizeOptimizations: SizeOptimizationAnalysis

    /// Overall health score (0-100)
    public var healthScore: Int {
        var score = 100

        // Deduct for layer issues
        score -= layerEfficiency.issues.count * 5

        // Deduct for cache invalidators
        score -= cacheability.cacheInvalidators.count * 10

        // Deduct for security findings
        for finding in security.findings {
            switch finding.severity {
            case .high: score -= 20
            case .medium: score -= 10
            case .low: score -= 5
            }
        }

        // Deduct for size opportunities
        score -= min(sizeOptimizations.totalPotentialSavingMB / 50, 20)

        return max(0, score)
    }
}

/// Layer efficiency analysis.
public struct LayerEfficiencyAnalysis {
    public let issues: [LayerIssue]
}

public struct LayerIssue {
    public enum IssueType {
        case multipleLayers
        case unnecessaryFiles
        case largeLayer
        case inefficientOrdering
    }

    public let type: IssueType
    public let description: String
    public let suggestion: String
    public let estimatedImpact: Impact
}

public enum Impact {
    case low, medium, high
}

/// Cache analysis results.
public struct CacheabilityAnalysis {
    public let cacheInvalidators: [CacheInvalidator]
    public let estimatedCacheHitRate: Double
}

public struct CacheInvalidator {
    public let operation: String
    public let reason: String
    public let suggestion: String
}

/// Security analysis results.
public struct SecurityAnalysis {
    public let findings: [SecurityFinding]
}

public struct SecurityFinding {
    public enum Severity {
        case low, medium, high
    }

    public enum FindingType {
        case rootUser
        case privilegedExecution
        case unverifiedDownload
        case unpinnedDependencies
        case exposedSecrets
    }

    public let severity: Severity
    public let type: FindingType
    public let description: String
    public let remediation: String
}

/// Size optimization analysis.
public struct SizeOptimizationAnalysis {
    public let opportunities: [SizeOptimization]

    public var totalPotentialSavingMB: Int {
        opportunities.reduce(0) { $0 + $1.estimatedSavingMB }
    }
}

public struct SizeOptimization {
    public enum OptimizationType {
        case packageManagerCache
        case buildDependencies
        case unnecessaryFiles
        case separateCleanupLayer
        case duplicateFiles
    }

    public let type: OptimizationType
    public let description: String
    public let estimatedSavingMB: Int
    public let suggestion: String
}

// MARK: - Reporting

extension SemanticAnalyzer {
    private func reportFindings(_ analysis: SemanticAnalysis, context: AnalysisContext) {
        guard let reporter = context.reporter else { return }

        // Report layer efficiency issues
        for issue in analysis.layerEfficiency.issues {
            let description = "\(issue.description). \(issue.suggestion)"
            let eventType: IREventType = issue.estimatedImpact == .high ? .error : .warning
            Task {
                await reporter.report(
                    .irEvent(
                        context: ReportContext(
                            description: description,
                            sourceMap: nil
                        ),
                        type: eventType
                    ))
            }
        }

        // Report security findings
        for finding in analysis.security.findings {
            let description = "\(finding.description). \(finding.remediation)"
            let eventType: IREventType = finding.severity == .high ? .error : .warning
            Task {
                await reporter.report(
                    .irEvent(
                        context: ReportContext(
                            description: description,
                            sourceMap: nil
                        ),
                        type: eventType
                    ))
            }
        }

        // Report cache invalidators
        for invalidator in analysis.cacheability.cacheInvalidators {
            let description = "Cache invalidator: \(invalidator.reason). \(invalidator.suggestion)"
            Task {
                await reporter.report(
                    .irEvent(
                        context: ReportContext(
                            description: description,
                            sourceMap: nil
                        ),
                        type: .warning
                    ))
            }
        }

        // Report size optimizations
        for optimization in analysis.sizeOptimizations.opportunities {
            if optimization.estimatedSavingMB > 100 {
                let description = "\(optimization.description). \(optimization.suggestion) (potential saving: \(optimization.estimatedSavingMB)MB)"
                Task {
                    await reporter.report(
                        .irEvent(
                            context: ReportContext(
                                description: description,
                                sourceMap: nil
                            ),
                            type: .warning
                        ))
                }
            }
        }
    }
}
