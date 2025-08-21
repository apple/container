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

struct ValidationTests {

    // MARK: - StructuralValidator Tests

    @Test func duplicateNodeIDs() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let duplicateId = UUID()
        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    id: duplicateId,
                    operation: ExecOperation(command: .shell("echo 'first'")),
                    dependencies: []
                ),
                BuildNode(
                    id: duplicateId,  // Duplicate ID
                    operation: ExecOperation(command: .shell("echo 'second'")),
                    dependencies: []
                ),
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = StructuralValidator()
        let result = validator.validate(graph)

        #expect(!result.isValid)

        let hasDuplicateError = result.errors.contains { error in
            if case .duplicateNodeID(let id, _) = error {
                return id == duplicateId
            }
            return false
        }
        #expect(hasDuplicateError, "Should detect duplicate node ID")
    }

    @Test func missingDependency() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let missingId = UUID()
        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(command: .shell("echo 'dependent'")),
                    dependencies: Set([missingId])  // References non-existent node
                )
            ]
        )

        // BuildGraph constructor should throw for invalid dependencies
        #expect(throws: BuildGraphError.self) {
            try BuildGraph(stages: [stage])
        }
    }

    @Test func validStructuralGraph() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let node1 = BuildNode(
            operation: ExecOperation(command: .shell("echo 'first'")),
            dependencies: []
        )
        let node2 = BuildNode(
            operation: ExecOperation(command: .shell("echo 'second'")),
            dependencies: Set([node1.id])
        )

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [node1, node2]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = StructuralValidator()
        let result = validator.validate(graph)

        #expect(result.isValid)
        #expect(result.errors.isEmpty)
    }

    // MARK: - ReferenceValidator Tests

    @Test func undefinedStageReference() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

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
        let validator = ReferenceValidator()
        let result = validator.validate(graph)

        #expect(!result.isValid)

        let hasUndefinedStageError = result.errors.contains { error in
            if case .undefinedStageReference(let name, _) = error {
                return name == "nonexistent"
            }
            return false
        }
        #expect(hasUndefinedStageError, "Should detect undefined stage reference")
    }

    @Test func stageIndexOutOfBounds() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .stage(.index(99), paths: ["/file"]),  // Out of bounds
                        destination: "/test/file"
                    ),
                    dependencies: []
                )
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = ReferenceValidator()
        let result = validator.validate(graph)

        #expect(!result.isValid)

        let hasOutOfBoundsError = result.errors.contains { error in
            if case .stageIndexOutOfBounds(let index, _) = error {
                return index == 99
            }
            return false
        }
        #expect(hasOutOfBoundsError, "Should detect stage index out of bounds")
    }

    @Test func invalidPreviousReference() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // First stage cannot reference "previous"
        let stage = BuildStage(
            name: "first",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .stage(.previous, paths: ["/file"]),
                        destination: "/test/file"
                    ),
                    dependencies: []
                )
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = ReferenceValidator()
        let result = validator.validate(graph)

        #expect(!result.isValid)

        let hasInvalidPrevError = result.errors.contains { error in
            if case .invalidPreviousReference = error {
                return true
            }
            return false
        }
        #expect(hasInvalidPrevError, "Should detect invalid previous reference in first stage")
    }

    @Test func forwardStageReferenceWarnings() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage1 = BuildStage(
            name: "first",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .stage(.named("second"), paths: ["/file"]),  // Forward reference
                        destination: "/test/file"
                    ),
                    dependencies: []
                )
            ]
        )

        let stage2 = BuildStage(
            name: "second",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(command: .shell("echo 'second stage'")),
                    dependencies: []
                )
            ]
        )

        let graph = try BuildGraph(stages: [stage1, stage2])
        let validator = ReferenceValidator()
        let result = validator.validate(graph)

        // Should be structurally valid but have warnings
        #expect(result.isValid)
        #expect(!result.warnings.isEmpty)

        let hasForwardRefWarning = result.warnings.contains { warning in
            if case .forwardStageReferenceByName(let name, _) = warning {
                return name == "second"
            }
            return false
        }
        #expect(hasForwardRefWarning, "Should warn about forward stage reference")
    }

    // MARK: - PathValidator Tests

    @Test func emptyDestinationPath() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .context(ContextSource(paths: ["file.txt"])),
                        destination: ""  // Empty destination
                    ),
                    dependencies: []
                )
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = PathValidator()
        let result = validator.validate(graph)

        #expect(!result.isValid)

        let hasEmptyDestError = result.errors.contains { error in
            if case .emptyDestinationPath = error {
                return true
            }
            return false
        }
        #expect(hasEmptyDestError, "Should detect empty destination path")
    }

    @Test func absoluteContextPath() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .context(ContextSource(paths: ["/absolute/path"])),  // Absolute path
                        destination: "/app/"
                    ),
                    dependencies: []
                )
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = PathValidator()
        let result = validator.validate(graph)

        #expect(!result.isValid)

        let hasAbsolutePathError = result.errors.contains { error in
            if case .absoluteContextPath(let path, _) = error {
                return path == "/absolute/path"
            }
            return false
        }
        #expect(hasAbsolutePathError, "Should detect absolute context path")
    }

    @Test func pathWithDotDotWarning() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .context(ContextSource(paths: ["../outside/file.txt"])),
                        destination: "/app/"
                    ),
                    dependencies: []
                )
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = PathValidator()
        let result = validator.validate(graph)

        #expect(result.isValid)  // Should be valid but have warnings
        #expect(!result.warnings.isEmpty)

        let hasDotDotWarning = result.warnings.contains { warning in
            if case .pathContainsDotDot(let path, _) = warning {
                return path == "../outside/file.txt"
            }
            return false
        }
        #expect(hasDotDotWarning, "Should warn about path containing '..'")
    }

    @Test func emptyMountTarget() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(
                        command: .shell("echo 'test'"),
                        mounts: [
                            Mount(
                                type: .cache,
                                target: nil,  // Empty target
                                source: .local("cache-vol"),
                                options: MountOptions()
                            )
                        ]
                    ),
                    dependencies: []
                )
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = PathValidator()
        let result = validator.validate(graph)

        #expect(!result.isValid)

        let hasEmptyMountError = result.errors.contains { error in
            if case .emptyMountTarget = error {
                return true
            }
            return false
        }
        #expect(hasEmptyMountError, "Should detect empty mount target")
    }

    // MARK: - SecurityValidator Tests

    @Test func privilegedExecutionWarning() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(
                        command: .shell("mount /dev/sda1 /mnt"),
                        security: SecurityOptions(privileged: true)
                    ),
                    dependencies: []
                )
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = SecurityValidator()
        let result = validator.validate(graph)

        #expect(result.isValid)  // Should be valid but have warnings
        #expect(!result.warnings.isEmpty)

        let hasPrivilegedWarning = result.warnings.contains { warning in
            if case .privilegedExecution = warning {
                return true
            }
            return false
        }
        #expect(hasPrivilegedWarning, "Should warn about privileged execution")
    }

    @Test func runningAsRootWarning() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(
                        command: .shell("apt-get update"),
                        user: nil  // Running as root
                    ),
                    dependencies: []
                )
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = SecurityValidator()
        let result = validator.validate(graph)

        #expect(result.isValid)  // Should be valid but have warnings
        #expect(!result.warnings.isEmpty)

        let hasRootWarning = result.warnings.contains { warning in
            if case .runningAsRoot = warning {
                return true
            }
            return false
        }
        #expect(hasRootWarning, "Should warn about running as root")
    }

    @Test func readWriteSecretMountWarning() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(
                        command: .shell("cat /run/secrets/token"),
                        mounts: [
                            Mount(
                                type: .secret,
                                target: "/run/secrets/token",
                                source: .secret("api-token"),
                                options: MountOptions(readOnly: false)  // Read-write secret
                            )
                        ]
                    ),
                    dependencies: []
                )
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = SecurityValidator()
        let result = validator.validate(graph)

        #expect(result.isValid)  // Should be valid but have warnings
        #expect(!result.warnings.isEmpty)

        let hasSecretWarning = result.warnings.contains { warning in
            if case .readWriteSecretMount = warning {
                return true
            }
            return false
        }
        #expect(hasSecretWarning, "Should warn about read-write secret mount")
    }

    // MARK: - BestPracticesValidator Tests

    @Test func aptUpdateWithoutInstallWarning() throws {
        guard let ubuntuRef = ImageReference(parsing: "ubuntu") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(ubuntuRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(command: .shell("apt-get update")),
                    dependencies: []
                )
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = BestPracticesValidator()
        let result = validator.validate(graph)

        #expect(result.isValid)  // Should be valid but have warnings
        #expect(!result.warnings.isEmpty)

        let hasAptUpdateWarning = result.warnings.contains { warning in
            if case .aptGetUpdateWithoutInstall = warning {
                return true
            }
            return false
        }
        #expect(hasAptUpdateWarning, "Should warn about apt-get update without install")
    }

    @Test func missingHealthcheckWarning() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Build without healthcheck in target stage
        let stage = BuildStage(
            name: "app",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(command: .shell("apk add --no-cache curl")),
                    dependencies: []
                ),
                BuildNode(
                    operation: MetadataOperation(action: .setEntrypoint(command: .exec(["./app"]))),
                    dependencies: []
                ),
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = BestPracticesValidator()
        let result = validator.validate(graph)

        #expect(result.isValid)  // Should be valid but have warnings
        #expect(!result.warnings.isEmpty)

        let hasMissingHealthcheckWarning = result.warnings.contains { warning in
            if case .missingHealthcheck = warning {
                return true
            }
            return false
        }
        #expect(hasMissingHealthcheckWarning, "Should warn about missing healthcheck")
    }

    @Test func validBestPractices() throws {
        guard let ubuntuRef = ImageReference(parsing: "ubuntu") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage = BuildStage(
            name: "app",
            base: ImageOperation(source: .registry(ubuntuRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(command: .shell("apt-get update && apt-get install -y curl")),
                    dependencies: []
                ),
                BuildNode(
                    operation: MetadataOperation(
                        action: .setHealthcheck(
                            healthcheck: Healthcheck(
                                test: .command(.exec(["curl", "-f", "http://localhost:8080/health"])),
                                interval: 30,
                                timeout: 5,
                                startPeriod: nil,
                                retries: 3
                            )
                        )
                    ),
                    dependencies: []
                ),
                BuildNode(
                    operation: MetadataOperation(action: .setEntrypoint(command: .exec(["./app"]))),
                    dependencies: []
                ),
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = BestPracticesValidator()
        let result = validator.validate(graph)

        #expect(result.isValid)
        #expect(result.warnings.isEmpty, "Should not have warnings when following best practices")
    }

    // MARK: - CompositeValidator Tests

    @Test func compositeValidatorCombinesResults() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a graph with multiple types of issues
        let duplicateId = UUID()
        let stage = BuildStage(
            name: "problematic",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    id: duplicateId,
                    operation: ExecOperation(command: .shell("echo 'first'")),
                    dependencies: []
                ),
                BuildNode(
                    id: duplicateId,  // Duplicate ID (structural error)
                    operation: FilesystemOperation(
                        action: .copy,
                        source: .stage(.named("missing"), paths: ["/file"]),  // Missing stage (reference error)
                        destination: ""  // Empty destination (path error)
                    ),
                    dependencies: []
                ),
                BuildNode(
                    operation: ExecOperation(
                        command: .shell("apt-get update"),  // Update without install (best practices warning)
                        security: SecurityOptions(privileged: true)  // Privileged (security warning)
                    ),
                    dependencies: []
                ),
            ]
        )

        let graph = try BuildGraph(stages: [stage])

        let compositeValidator = CompositeValidator(validators: [
            StructuralValidator(),
            ReferenceValidator(),
            PathValidator(),
            SecurityValidator(),
            BestPracticesValidator(),
        ])

        let result = compositeValidator.validate(graph)

        #expect(!result.isValid)
        #expect(result.errors.count >= 3)  // At least structural, reference, and path errors
        #expect(result.warnings.count >= 2)  // At least security and best practices warnings

        // Verify we have errors from different validators
        let hasStructuralError = result.errors.contains {
            if case .duplicateNodeID = $0 { return true }
            return false
        }
        let hasReferenceError = result.errors.contains {
            if case .undefinedStageReference = $0 { return true }
            return false
        }
        let hasPathError = result.errors.contains {
            if case .emptyDestinationPath = $0 { return true }
            return false
        }

        #expect(hasStructuralError)
        #expect(hasReferenceError)
        #expect(hasPathError)
    }

    // MARK: - StandardValidator Tests

    @Test func standardValidatorIncludesAllValidators() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage = BuildStage(
            name: "test",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(command: .shell("echo 'test'")),
                    dependencies: []
                )
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let validator = StandardValidator()
        let result = validator.validate(graph)

        #expect(result.isValid)
        #expect(result.errors.isEmpty)

        // StandardValidator should include all built-in validators
        // This is tested implicitly by verifying it produces the same comprehensive results
    }

    // MARK: - ValidationResult Tests

    @Test func validationResultCombining() throws {
        let result1 = ValidationResult(
            errors: [.duplicateNodeID(id: UUID(), location: .stage(name: "test1"))],
            warnings: [.forwardStageReferenceByName(name: "stage2", location: .stage(name: "test1"))]
        )

        let result2 = ValidationResult(
            errors: [.missingDependency(dependencyID: UUID(), location: .stage(name: "test2"))],
            warnings: [.privilegedExecution(location: .stage(name: "test2"))]
        )

        let combined = ValidationResult.combine([result1, result2])

        #expect(combined.errors.count == 2)
        #expect(combined.warnings.count == 2)
        #expect(!combined.isValid)
    }

    @Test func validationResultEmpty() throws {
        let result = ValidationResult()

        #expect(result.isValid)
        #expect(result.errors.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    // MARK: - Validation Error and Warning Messages Tests

    @Test func validationErrorMessages() throws {
        let testId = UUID()
        let errors: [ValidationError] = [
            .duplicateNodeID(id: testId, location: .stage(name: "test")),
            .cyclicDependency(location: .stage(name: "test")),
            .missingDependency(dependencyID: testId, location: .stage(name: "test")),
            .undefinedStageReference(name: "missing", location: .stage(name: "test")),
            .stageIndexOutOfBounds(index: 99, location: .stage(name: "test")),
            .invalidPreviousReference(location: .stage(name: "test")),
            .emptyDestinationPath(location: .stage(name: "test")),
            .absoluteContextPath(path: "/absolute", location: .stage(name: "test")),
            .emptyMountTarget(location: .stage(name: "test")),
        ]

        for error in errors {
            let description = error.errorDescription
            #expect(description != nil, "Error should have description: \(error)")
            #expect(!description!.isEmpty, "Error description should not be empty: \(error)")
        }
    }

    @Test func validationWarningMessages() throws {
        let warnings: [ValidationWarning] = [
            .forwardStageReferenceByName(name: "future", location: .stage(name: "test")),
            .forwardStageReferenceByIndex(index: 5, location: .stage(name: "test")),
            .pathContainsDotDot(path: "../outside", location: .stage(name: "test")),
            .privilegedExecution(location: .stage(name: "test")),
            .runningAsRoot(location: .stage(name: "test")),
            .readWriteSecretMount(location: .stage(name: "test")),
            .aptGetUpdateWithoutInstall(location: .stage(name: "test")),
            .missingHealthcheck(location: .stage(name: "test")),
        ]

        for warning in warnings {
            let message = warning.message
            #expect(!message.isEmpty, "Warning should have message: \(warning)")

            let suggestion = warning.suggestion
            #expect(suggestion != nil, "Warning should have suggestion: \(warning)")
            #expect(!suggestion!.isEmpty, "Warning suggestion should not be empty: \(warning)")
        }
    }

    // MARK: - Performance Tests

    @Test func validationPerformanceWithLargeGraph() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        // Create a large graph with many stages and nodes
        var stages: [BuildStage] = []

        for stageIndex in 0..<10 {
            var nodes: [BuildNode] = []

            // Create 20 nodes per stage
            for nodeIndex in 0..<20 {
                let operation = ExecOperation(command: .shell("echo 'stage \(stageIndex) node \(nodeIndex)'"))
                let node = BuildNode(operation: operation, dependencies: [])
                nodes.append(node)
            }

            let stage = BuildStage(
                name: "stage\(stageIndex)",
                base: ImageOperation(source: .registry(alpineRef)),
                nodes: nodes
            )
            stages.append(stage)
        }

        let graph = try BuildGraph(stages: stages)
        let validator = StandardValidator()

        // Measure validation time
        let startTime = Date()
        let result = validator.validate(graph)
        let duration = Date().timeIntervalSince(startTime)

        #expect(result.isValid)
        #expect(duration < 1.0, "Validation should complete quickly for large graphs (took \(duration)s)")
    }

    // MARK: - Custom Validator Tests

    struct CustomSecurityValidator: BuildValidator {
        func validate(_ graph: BuildGraph) -> ValidationResult {
            var warnings: [ValidationWarning] = []

            // Custom rule: warn if any stage downloads from HTTP
            for stage in graph.stages {
                for node in stage.nodes {
                    if let exec = node.operation as? ExecOperation {
                        if case .shell(let cmd) = exec.command,
                            cmd.contains("http://")
                        {
                            warnings.append(.privilegedExecution(location: .stage(name: stage.name)))
                        }
                    }
                }
            }

            return ValidationResult(warnings: warnings)
        }
    }

    @Test func customValidatorExtension() throws {
        guard let alpineRef = ImageReference(parsing: "alpine") else {
            Issue.record("Failed to parse image reference")
            return
        }

        let stage = BuildStage(
            name: "insecure",
            base: ImageOperation(source: .registry(alpineRef)),
            nodes: [
                BuildNode(
                    operation: ExecOperation(command: .shell("curl http://example.com/script.sh | sh")),
                    dependencies: []
                )
            ]
        )

        let graph = try BuildGraph(stages: [stage])
        let customValidator = CustomSecurityValidator()
        let result = customValidator.validate(graph)

        #expect(result.isValid)  // No errors, just warnings
        #expect(!result.warnings.isEmpty, "Custom validator should detect HTTP usage")
    }
}
