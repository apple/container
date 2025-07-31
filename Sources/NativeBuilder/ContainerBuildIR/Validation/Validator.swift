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

/// Protocol for build graph validators.
///
/// Design rationale:
/// - Composable validation rules
/// - Collect all errors rather than fail-fast
/// - Extensible for custom validation
public protocol BuildValidator {
    /// Validate a build graph
    func validate(_ graph: BuildGraph) -> ValidationResult
}

/// Result of validation.
public struct ValidationResult {
    public let errors: [ValidationError]
    public let warnings: [ValidationWarning]

    public var isValid: Bool { errors.isEmpty }

    public init(errors: [ValidationError] = [], warnings: [ValidationWarning] = []) {
        self.errors = errors
        self.warnings = warnings
    }

    /// Combine multiple results
    public static func combine(_ results: [ValidationResult]) -> ValidationResult {
        ValidationResult(
            errors: results.flatMap { $0.errors },
            warnings: results.flatMap { $0.warnings }
        )
    }
}

// MARK: - Validation Error Enum

/// A structured error that prevents a build from proceeding.
public enum ValidationError: Error, LocalizedError, Sendable {
    // Structural Errors
    case duplicateNodeID(id: UUID, location: ValidationLocation)
    case cyclicDependency(location: ValidationLocation)
    case missingDependency(dependencyID: UUID, location: ValidationLocation)

    // Reference Errors
    case undefinedStageReference(name: String, location: ValidationLocation)
    case stageIndexOutOfBounds(index: Int, location: ValidationLocation)
    case invalidPreviousReference(location: ValidationLocation)

    // Path Errors
    case emptyDestinationPath(location: ValidationLocation)
    case absoluteContextPath(path: String, location: ValidationLocation)
    case emptyMountTarget(location: ValidationLocation)

    public var errorDescription: String? {
        switch self {
        case .duplicateNodeID(let id, _):
            return "Duplicate node ID found: \(id)."
        case .cyclicDependency:
            return "Stage contains a cyclic dependency."
        case .missingDependency(let dependencyID, _):
            return "Node references a non-existent dependency: \(dependencyID)."
        case .undefinedStageReference(let name, _):
            return "Reference to an undefined stage: '\(name)'."
        case .stageIndexOutOfBounds(let index, _):
            return "Stage index is out of bounds: \(index)."
        case .invalidPreviousReference:
            return "Cannot reference the previous stage from the first stage."
        case .emptyDestinationPath:
            return "Filesystem operation has an empty destination path."
        case .absoluteContextPath(let path, _):
            return "Source path for a context operation must be relative, but found absolute path: '\(path)'."
        case .emptyMountTarget:
            return "An execution mount has an empty target path."
        }
    }
}

// MARK: - Validation Warning Enum

/// A structured warning that does not prevent a build but indicates a potential issue.
public enum ValidationWarning: Sendable {
    // Reference Warnings
    case forwardStageReferenceByName(name: String, location: ValidationLocation)
    case forwardStageReferenceByIndex(index: Int, location: ValidationLocation)

    // Path Warnings
    case pathContainsDotDot(path: String, location: ValidationLocation)

    // Security Warnings
    case privilegedExecution(location: ValidationLocation)
    case runningAsRoot(location: ValidationLocation)
    case readWriteSecretMount(location: ValidationLocation)

    // Best Practice Warnings
    case aptGetUpdateWithoutInstall(location: ValidationLocation)
    case missingHealthcheck(location: ValidationLocation)

    /// A human-readable description of the warning.
    public var message: String {
        switch self {
        case .forwardStageReferenceByName(let name, _):
            return "Forward reference to stage '\(name)'. Build may be inefficient."
        case .forwardStageReferenceByIndex(let index, _):
            return "Forward reference to stage at index \(index). Build may be inefficient."
        case .pathContainsDotDot(let path, _):
            return "Path contains '..', which could lead to accessing files outside the build context: '\(path)'."
        case .privilegedExecution:
            return "Operation is configured to run with privileged access."
        case .runningAsRoot:
            return "Operation is configured to run as the root user."
        case .readWriteSecretMount:
            return "A secret is mounted as read-write, which is insecure."
        case .aptGetUpdateWithoutInstall:
            return "'apt-get update' is run in a separate command from 'apt-get install'."
        case .missingHealthcheck:
            return "The final image has no HEALTHCHECK defined."
        }
    }

    /// A suggestion for how to resolve the warning.
    public var suggestion: String? {
        switch self {
        case .forwardStageReferenceByName, .forwardStageReferenceByIndex:
            return "Consider reordering stages to ensure all dependencies are built first."
        case .pathContainsDotDot:
            return "Use explicit paths from the context root instead of relative parent paths."
        case .privilegedExecution:
            return "Ensure the operation truly requires privileged mode to run."
        case .runningAsRoot:
            return "Consider specifying a non-root user with the USER instruction for enhanced security."
        case .readWriteSecretMount:
            return "Secrets should always be mounted as read-only."
        case .aptGetUpdateWithoutInstall:
            return "Combine 'apt-get update' and 'apt-get install' in the same RUN command to reduce image layers and ensure cache correctness."
        case .missingHealthcheck:
            return "Consider adding a HEALTHCHECK instruction to your final stage for production-ready images."
        }
    }
}

/// Location information for validation messages.
public enum ValidationLocation: Sendable {
    case stage(name: String?)
    case node(stageIndex: Int, nodeIndex: Int)
    case operation(OperationKind)
    case sourceLocation(SourceLocation)
}

/// Composite validator that runs multiple validators.
public struct CompositeValidator: BuildValidator, Sendable {
    private let validators: [any BuildValidator & Sendable]

    public init(validators: [any BuildValidator & Sendable]) {
        self.validators = validators
    }

    public func validate(_ graph: BuildGraph) -> ValidationResult {
        ValidationResult.combine(validators.map { $0.validate(graph) })
    }
}

/// Standard validator with all built-in rules.
public struct StandardValidator: BuildValidator, Sendable {
    private let validator: CompositeValidator

    public init() {
        validator = CompositeValidator(validators: [
            StructuralValidator(),
            ReferenceValidator(),
            PathValidator(),
            SecurityValidator(),
            BestPracticesValidator(),
        ])
    }

    public func validate(_ graph: BuildGraph) -> ValidationResult {
        validator.validate(graph)
    }
}

/// Validates graph structure (cycles, dependencies).
public struct StructuralValidator: BuildValidator, Sendable {
    public func validate(_ graph: BuildGraph) -> ValidationResult {
        var errors: [ValidationError] = []

        // Check each stage
        for (_, stage) in graph.stages.enumerated() {
            let stageLocation = ValidationLocation.stage(name: stage.name)
            // Check for duplicate node IDs
            var seenIds = Set<UUID>()
            for node in stage.nodes {
                if !seenIds.insert(node.id).inserted {
                    errors.append(.duplicateNodeID(id: node.id, location: stageLocation))
                }
            }

            // Cycle detection will be done globally due to cross-stage dependencies

            // Dependencies will be checked globally after collecting all node IDs
        }

        // Collect all node IDs across all stages
        var allNodeIds = Set<UUID>()
        for stage in graph.stages {
            for node in stage.nodes {
                allNodeIds.insert(node.id)
            }
        }

        // Now check that all dependencies exist (can be cross-stage)
        for (stageIndex, stage) in graph.stages.enumerated() {
            for (nodeIndex, node) in stage.nodes.enumerated() {
                for dep in node.dependencies {
                    if !allNodeIds.contains(dep) {
                        let nodeLocation = ValidationLocation.node(stageIndex: stageIndex, nodeIndex: nodeIndex)
                        errors.append(.missingDependency(dependencyID: dep, location: nodeLocation))
                    }
                }
            }
        }

        return ValidationResult(errors: errors)
    }
}

/// Validates cross-stage references.
public struct ReferenceValidator: BuildValidator, Sendable {
    public func validate(_ graph: BuildGraph) -> ValidationResult {
        var errors: [ValidationError] = []
        var warnings: [ValidationWarning] = []

        for (stageIndex, stage) in graph.stages.enumerated() {
            let stageLocation = ValidationLocation.stage(name: stage.name)
            let stageDeps = stage.stageDependencies()

            for dep in stageDeps {
                // Validate reference exists
                let exists: Bool
                switch dep {
                case .named(let name):
                    exists = graph.stages.contains { $0.name == name }
                    if !exists {
                        errors.append(.undefinedStageReference(name: name, location: stageLocation))
                    }
                case .index(let idx):
                    exists = idx >= 0 && idx < graph.stages.count
                    if !exists {
                        errors.append(.stageIndexOutOfBounds(index: idx, location: stageLocation))
                    }
                case .previous:
                    exists = stageIndex > 0
                    if !exists {
                        errors.append(.invalidPreviousReference(location: stageLocation))
                    }
                }

                // Check for forward references (warning)
                if exists {
                    switch dep {
                    case .named(let name):
                        if let depIndex = graph.stages.firstIndex(where: { $0.name == name }),
                            depIndex > stageIndex
                        {
                            warnings.append(.forwardStageReferenceByName(name: name, location: stageLocation))
                        }
                    case .index(let idx):
                        if idx > stageIndex {
                            warnings.append(.forwardStageReferenceByIndex(index: idx, location: stageLocation))
                        }
                    case .previous:
                        break  // Always valid
                    }
                }
            }
        }

        return ValidationResult(errors: errors, warnings: warnings)
    }
}

/// Validates filesystem paths and operations.
public struct PathValidator: BuildValidator, Sendable {
    public func validate(_ graph: BuildGraph) -> ValidationResult {
        var errors: [ValidationError] = []
        var warnings: [ValidationWarning] = []

        for stage in graph.stages {
            for node in stage.nodes {
                if let fsOp = node.operation as? FilesystemOperation {
                    let opLocation = ValidationLocation.operation(node.operation.operationKind)
                    // Validate destination path
                    if fsOp.destination.isEmpty {
                        errors.append(.emptyDestinationPath(location: opLocation))
                    }

                    // Check for absolute paths in context source
                    if case .context(let source) = fsOp.source {
                        for path in source.paths {
                            if path.hasPrefix("/") {
                                errors.append(.absoluteContextPath(path: path, location: opLocation))
                            }

                            if path.contains("..") {
                                warnings.append(.pathContainsDotDot(path: path, location: opLocation))
                            }
                        }
                    }
                }

                // Validate mount paths
                if let execOp = node.operation as? ExecOperation {
                    let opLocation = ValidationLocation.operation(node.operation.operationKind)
                    for mount in execOp.mounts {
                        if mount.target == nil && mount.envTarget == nil {
                            errors.append(.emptyMountTarget(location: opLocation))
                        }
                    }
                }
            }
        }

        return ValidationResult(errors: errors, warnings: warnings)
    }
}

/// Validates security constraints.
public struct SecurityValidator: BuildValidator, Sendable {
    public func validate(_ graph: BuildGraph) -> ValidationResult {
        var warnings: [ValidationWarning] = []

        for stage in graph.stages {
            for node in stage.nodes {
                if let execOp = node.operation as? ExecOperation {
                    let opLocation = ValidationLocation.operation(node.operation.operationKind)
                    // Warn about privileged execution
                    if execOp.security.privileged {
                        warnings.append(.privilegedExecution(location: opLocation))
                    }

                    // Warn about running as root
                    if execOp.user == nil {
                        warnings.append(.runningAsRoot(location: opLocation))
                    }

                    // Check for secret mounts
                    for mount in execOp.mounts {
                        if mount.type == .secret && !mount.options.readOnly {
                            warnings.append(.readWriteSecretMount(location: opLocation))
                        }
                    }
                }
            }
        }

        return ValidationResult(warnings: warnings)
    }
}

/// Validates against best practices.
public struct BestPracticesValidator: BuildValidator, Sendable {
    public func validate(_ graph: BuildGraph) -> ValidationResult {
        var warnings: [ValidationWarning] = []

        for stage in graph.stages {
            var hasHealthcheck = false

            for node in stage.nodes {
                let opLocation = ValidationLocation.operation(node.operation.operationKind)
                // Check for multiple RUN commands that could be combined
                if let execOp = node.operation as? ExecOperation {
                    if case .shell(let cmd) = execOp.command {
                        if cmd.contains("apt-get update") && !cmd.contains("apt-get install") {
                            warnings.append(.aptGetUpdateWithoutInstall(location: opLocation))
                        }
                    }
                }

                // Track user changes
                if let metaOp = node.operation as? MetadataOperation {
                    if case .setHealthcheck = metaOp.action {
                        hasHealthcheck = true
                    }
                }
            }

            // Warn if no healthcheck defined
            if !hasHealthcheck && stage == graph.targetStage {
                let stageLocation = ValidationLocation.stage(name: stage.name)
                warnings.append(.missingHealthcheck(location: stageLocation))
            }
        }

        return ValidationResult(warnings: warnings)
    }
}
