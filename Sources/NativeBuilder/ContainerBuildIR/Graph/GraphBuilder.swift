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

/// Errors that can occur during graph building
public enum GraphBuilderError: Error, LocalizedError {
    case noActiveStage
    case invalidOperation(String)
    case missingDependency(UUID)

    public var errorDescription: String? {
        switch self {
        case .noActiveStage:
            return "No active stage. Call stage() or scratch() first."
        case .invalidOperation(let message):
            return "Invalid operation: \(message)"
        case .missingDependency(let id):
            return "Missing dependency with ID: \(id)"
        }
    }
}

/// Builder for constructing build graphs.
///
/// Design rationale:
/// - Fluent API for easy graph construction
/// - Validates as you build to catch errors early
/// - Handles dependency resolution automatically
/// - Supports incremental construction
public final class GraphBuilder {
    private var stages: [BuildStage] = []
    private var currentStage: StageBuilder?
    private var buildArgs: [String: String] = [:]
    private var targetPlatforms: Set<Platform> = []
    private var metadata = BuildGraphMetadata()
    private let graphAnalyzers: [any GraphAnalyzer]
    private let stageAnalyzers: [any StageAnalyzer]
    private let reporter: Reporter?

    /// Public initializer with optional reporter
    public init(reporter: Reporter? = nil) {
        self.graphAnalyzers = Self.defaultGraphAnalyzers
        self.stageAnalyzers = Self.defaultStageAnalyzers
        self.reporter = reporter
    }

    /// Internal initializer for custom analyzers
    internal init(
        graphAnalyzers: [any GraphAnalyzer],
        stageAnalyzers: [any StageAnalyzer],
        reporter: Reporter? = nil
    ) {
        self.graphAnalyzers = graphAnalyzers
        self.stageAnalyzers = stageAnalyzers
        self.reporter = reporter
    }

    /// Default graph analyzers
    private nonisolated(unsafe) static let defaultGraphAnalyzers: [any GraphAnalyzer] = [
        DependencyAnalyzer(),
        ValidatorAnalyzer(validator: StandardValidator()),
        SemanticAnalyzer(),
    ]

    /// Default stage analyzers (empty for now)
    private nonisolated(unsafe) static let defaultStageAnalyzers: [any StageAnalyzer] = []

    /// Start a new stage
    @discardableResult
    public func stage(
        name: String? = nil,
        from image: ImageReference,
        platform: Platform? = nil
    ) throws -> Self {
        // Finish current stage if any
        if let current = currentStage {
            stages.append(try current.build())
        }

        // Report stage creation
        if let reporter = reporter {
            Task {
                await reporter.report(
                    .irEvent(
                        context: ReportContext(
                            stageId: name,
                            description: "Creating stage \(name ?? "unnamed") from \(image)",
                            sourceMap: nil
                        ),
                        type: .stageAdded
                    ))
            }
        }

        // Create new stage
        let imageOp = ImageOperation(
            source: .registry(image),
            platform: platform
        )

        currentStage = StageBuilder(
            name: name,
            base: imageOp,
            platform: platform,
            analyzers: stageAnalyzers,
            reporter: reporter
        )
        return self
    }

    /// Start a stage from scratch
    @discardableResult
    public func scratch(name: String? = nil) throws -> Self {
        if let current = currentStage {
            stages.append(try current.build())
        }

        // Report stage creation
        if let reporter = reporter {
            Task {
                await reporter.report(
                    .irEvent(
                        context: ReportContext(
                            stageId: name,
                            description: "Creating stage \(name ?? "unnamed") from scratch",
                            sourceMap: nil
                        ),
                        type: .stageAdded
                    ))
            }
        }

        let imageOp = ImageOperation(source: .scratch)
        currentStage = StageBuilder(
            name: name,
            base: imageOp,
            analyzers: stageAnalyzers,
            reporter: reporter
        )
        return self
    }

    /// Add an operation to current stage
    @discardableResult
    public func add(_ operation: any Operation, dependsOn: [UUID] = []) throws -> Self {
        guard let current = currentStage else {
            throw GraphBuilderError.noActiveStage
        }

        current.add(operation, dependsOn: Set(dependsOn))
        return self
    }

    /// Add a RUN operation
    @discardableResult
    public func run(
        _ command: String,
        shell: Bool = true,
        env: [String: String] = [:],
        workdir: String? = nil,
        user: User? = nil,
        mounts: [Mount] = [],
        network: NetworkMode = .default,
    ) throws -> Self {
        let cmd = shell ? Command.shell(command) : Command.exec(command.split(separator: " ").map(String.init))
        return try runWithCmd(cmd, shell: shell, env: env, workdir: workdir, user: user, mounts: mounts, network: network)
    }

    @discardableResult
    public func runWithCmd(
        _ cmd: Command,
        shell: Bool = true,
        env: [String: String] = [:],
        workdir: String? = nil,
        user: User? = nil,
        mounts: [Mount] = [],
        network: NetworkMode = .default,
    ) throws -> Self {
        let envVars = env.map { (key: $0.key, value: EnvironmentValue.literal($0.value)) }
        let operation = ExecOperation(
            command: cmd,
            environment: Environment(envVars),
            mounts: mounts,
            workingDirectory: workdir,
            user: user,
            network: network,
        )

        return try add(operation)
    }

    /// Add a COPY operation
    @discardableResult
    public func copy(
        from source: FilesystemSource,
        to destination: String,
        chown: Ownership? = nil,
        chmod: Permissions? = nil
    ) throws -> Self {
        let operation = FilesystemOperation(
            action: .copy,
            source: source,
            destination: destination,
            fileMetadata: FileMetadata(
                ownership: chown,
                permissions: chmod ?? .preserve
            )
        )

        return try add(operation)
    }

    /// Add COPY from context
    @discardableResult
    public func copyFromContext(
        name: String = "default",
        paths: [String],
        to destination: String,
        chown: Ownership? = nil,
        chmod: Permissions? = nil
    ) throws -> Self {
        try copy(
            from: .context(ContextSource(name: name, paths: paths)),
            to: destination,
            chown: chown,
            chmod: chmod
        )
    }

    /// Add COPY from stage
    @discardableResult
    public func copyFromStage(
        _ stage: StageReference,
        paths: [String],
        to destination: String,
        chown: Ownership? = nil,
        chmod: Permissions? = nil
    ) throws -> Self {
        try copy(
            from: .stage(stage, paths: paths),
            to: destination,
            chown: chown,
            chmod: chmod
        )
    }

    /// Set environment variable
    @discardableResult
    public func env(_ key: String, _ value: String) throws -> Self {
        let operation = MetadataOperation(
            action: .setEnv(key: key, value: .literal(value))
        )
        return try add(operation)
    }

    /// Set working directory
    @discardableResult
    public func workdir(_ path: String) throws -> Self {
        let operation = MetadataOperation(action: .setWorkdir(path: path))
        return try add(operation)
    }

    /// Set user
    @discardableResult
    public func user(_ user: User) throws -> Self {
        let operation = MetadataOperation(action: .setUser(user: user))
        return try add(operation)
    }

    /// Add label
    @discardableResult
    public func label(_ key: String, _ value: String) throws -> Self {
        let operation = MetadataOperation(
            action: .setLabel(key: key, value: value)
        )
        return try add(operation)
    }

    @discardableResult
    public func labelBatch(labels: [String: String]) throws -> Self {
        let operation = MetadataOperation(
            action: .setLabelBatch(labels)
        )
        return try add(operation)
    }

    /// Expose port
    @discardableResult
    public func expose(_ ports: [PortSpec]) throws -> Self {
        let operation = MetadataOperation(
            action: .expose(ports: ports)
        )
        return try add(operation)
    }

    /// Set entrypoint
    @discardableResult
    public func entrypoint(_ command: Command) throws -> Self {
        let operation = MetadataOperation(action: .setEntrypoint(command: command))
        return try add(operation)
    }

    /// Set CMD
    @discardableResult
    public func cmd(_ command: Command) throws -> Self {
        let operation = MetadataOperation(action: .setCmd(command: command))
        return try add(operation)
    }

    /// Set healthcheck
    @discardableResult
    public func healthcheck(
        test: HealthcheckTest,
        interval: TimeInterval? = nil,
        timeout: TimeInterval? = nil,
        startPeriod: TimeInterval? = nil,
        retries: Int? = nil
    ) throws -> Self {
        let healthcheck = Healthcheck(
            test: test,
            interval: interval,
            timeout: timeout,
            startPeriod: startPeriod,
            retries: retries
        )
        let operation = MetadataOperation(action: .setHealthcheck(healthcheck: healthcheck))
        return try add(operation)
    }

    /// Add build argument
    @discardableResult
    public func arg(_ name: String, defaultValue: String? = nil) throws -> Self {
        buildArgs[name] = defaultValue
        let operation = MetadataOperation(
            action: .declareArg(name: name, defaultValue: defaultValue)
        )
        return try add(operation)
    }

    /// Set target platforms
    @discardableResult
    public func platforms(_ platforms: Platform...) -> Self {
        targetPlatforms = Set(platforms)
        return self
    }

    /// Set metadata
    @discardableResult
    public func metadata(
        sourceFile: String? = nil,
        contextPath: String? = nil,
        frontend: String? = nil
    ) -> Self {
        if let sourceFile = sourceFile {
            metadata = BuildGraphMetadata(
                sourceFile: sourceFile,
                contextPath: contextPath ?? metadata.contextPath,
                frontend: frontend ?? metadata.frontend
            )
        }
        return self
    }

    /// Build the final graph
    public func build() throws -> BuildGraph {
        // Report build start
        if let reporter = reporter {
            let stageCount = stages.count
            Task {
                await reporter.report(
                    .irEvent(
                        context: ReportContext(
                            description: "Building graph with \(stageCount) stages",
                            sourceMap: nil
                        ),
                        type: .graphStarted
                    ))
            }
        }

        // Add final stage if any
        if let current = currentStage {
            stages.append(try current.build())
            currentStage = nil
        }

        // Create initial graph
        var graph = try BuildGraph(
            stages: stages,
            buildArgs: buildArgs,
            targetPlatforms: targetPlatforms,
            metadata: metadata
        )

        // Create analysis context
        let analysisContext = AnalysisContext(reporter: reporter)

        // Run all graph analyzers in sequence
        for analyzer in graphAnalyzers {
            let analyzerName = String(describing: type(of: analyzer))

            // Report analyzer start
            if let reporter = reporter {
                Task {
                    await reporter.report(
                        .irEvent(
                            context: ReportContext(
                                description: "Running \(analyzerName)",
                                sourceMap: nil
                            ),
                            type: .analyzing
                        ))
                }
            }

            graph = try analyzer.analyze(graph, context: analysisContext)
        }

        // Report completion
        if let reporter = reporter {
            let totalNodes = graph.stages.reduce(0) { $0 + $1.nodes.count }
            let stageCount = graph.stages.count
            Task {
                await reporter.report(
                    .irEvent(
                        context: ReportContext(
                            description: "Graph built: \(stageCount) stages, \(totalNodes) nodes",
                            sourceMap: nil
                        ),
                        type: .graphCompleted
                    ))
            }
        }

        return graph
    }
}

/// Builder for individual stages.
private final class StageBuilder {
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

// MARK: - Convenience Extensions

extension GraphBuilder {
    /// Create a simple single-stage build
    public static func singleStage(
        name: String? = nil,
        from image: ImageReference,
        platform: Platform? = nil,
        reporter: Reporter? = nil,
        _ configure: (GraphBuilder) throws -> Void
    ) throws -> BuildGraph {
        let builder = GraphBuilder(reporter: reporter)
        if let platform = platform {
            builder.platforms(platform)
        }
        try builder.stage(name: name, from: image, platform: platform)
        try configure(builder)
        return try builder.build()
    }

    /// Create a multi-stage build
    public static func multiStage(
        reporter: Reporter? = nil,
        _ configure: (GraphBuilder) throws -> Void
    ) throws -> BuildGraph {
        let builder = GraphBuilder(reporter: reporter)
        try configure(builder)
        return try builder.build()
    }

    public func getStage(stageName: String) -> BuildStage? {
        for s in self.stages {
            if s.name == stageName {
                return s
            }
        }
        return nil
    }

    public func getBuildArg(key: String) -> String? {
        self.buildArgs[key]
    }
}
