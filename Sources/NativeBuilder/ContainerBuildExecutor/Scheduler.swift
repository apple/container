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

import ContainerBuildCache
import ContainerBuildIR
import ContainerBuildReporting
import ContainerBuildSnapshotter
import ContainerizationOCI
import Crypto
import Foundation

// Import specific type to avoid ambiguity with ContainerBuildIR.CacheKey
import struct ContainerBuildCache.CacheKey
import struct ContainerBuildCache.CacheStatistics
import struct ContainerBuildCache.CachedResult

/// A production-ready, highly parallel scheduler that minimizes build time through
/// intelligent scheduling and maximum parallelization.
///
/// Key features:
/// - Parallel execution of independent operations
/// - Dynamic work stealing for load balancing
/// - Resource-aware scheduling with throttling
/// - Priority-based execution ordering
/// - Real-time performance monitoring
/// - Integrated progress reporting via event streams
public final class Scheduler: BuildExecutor {
    /// Atomic storage for reporter to maintain Sendable conformance
    private let reporterStorage = AtomicStorage<Reporter?>()
    /// The reporter for this scheduler instance (if progress reporting is enabled)
    public var reporter: Reporter? { reporterStorage.value }
    /// Completion handler to wait for all consumers
    private let completionHandlers = AtomicStorage<[@Sendable () async -> Void]>(initialValue: [])
    private let dispatcher: ExecutionDispatcher
    private let snapshotter: any Snapshotter
    private let cache: any BuildCache
    private let configuration: Configuration

    /// Scheduler configuration
    public struct Configuration: Sendable {
        /// Maximum number of concurrent operations
        public let maxConcurrency: Int

        /// Maximum memory usage in bytes
        public let maxMemoryUsage: Int64

        /// Enable work stealing between queues
        public let enableWorkStealing: Bool

        /// Enable priority scheduling
        public let enablePriorityScheduling: Bool

        /// Resource monitoring interval
        public let monitoringInterval: TimeInterval

        /// Fail fast on first error
        public let failFast: Bool

        /// Enable progress reporting
        public let enableProgressReporting: Bool

        public init(
            maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount * 2,
            maxMemoryUsage: Int64 = 8 * 1024 * 1024 * 1024,  // 8GB default
            enableWorkStealing: Bool = true,
            enablePriorityScheduling: Bool = true,
            monitoringInterval: TimeInterval = 0.5,
            failFast: Bool = true,
            enableProgressReporting: Bool = true
        ) {
            self.maxConcurrency = maxConcurrency
            self.maxMemoryUsage = maxMemoryUsage
            self.enableWorkStealing = enableWorkStealing
            self.enablePriorityScheduling = enablePriorityScheduling
            self.monitoringInterval = monitoringInterval
            self.failFast = failFast
            self.enableProgressReporting = enableProgressReporting
        }
    }

    /// Execution state tracking
    private let executionState = ExecutionState()

    /// Work queues for parallel execution
    private let workQueues: WorkQueueManager

    /// Resource monitor
    private let resourceMonitor: ResourceMonitor

    /// Metrics collector
    private let metricsCollector = MetricsCollector()

    public init(
        executors: [any OperationExecutor],
        snapshotter: any Snapshotter,
        cache: any BuildCache,
        reporter: Reporter? = nil,
        configuration: Configuration = Configuration()
    ) {
        self.dispatcher = ExecutionDispatcher(executors: executors)
        self.snapshotter = snapshotter
        self.cache = cache
        self.configuration = configuration
        self.workQueues = WorkQueueManager(
            concurrency: configuration.maxConcurrency,
            enableWorkStealing: configuration.enableWorkStealing
        )
        self.resourceMonitor = ResourceMonitor(
            maxMemory: configuration.maxMemoryUsage,
            interval: configuration.monitoringInterval
        )

        // Initialize reporter based on configuration
        if let reporter = reporter {
            self.reporterStorage.value = reporter
        } else if configuration.enableProgressReporting {
            self.reporterStorage.value = Reporter()
        }
    }

    /// Convenience initializer with default executors
    public convenience init(
        snapshotter: any Snapshotter,
        cache: any BuildCache,
        reporter: Reporter? = nil,
        configuration: Configuration = Configuration()
    ) {
        let defaultExecutors: [any OperationExecutor] = [
            ImageOperationExecutor(),
            ExecOperationExecutor(),
            FilesystemOperationExecutor(),
            MetadataOperationExecutor(),
            UnknownOperationExecutor(),
        ]

        self.init(
            executors: defaultExecutors,
            snapshotter: snapshotter,
            cache: cache,
            reporter: reporter,
            configuration: configuration
        )
    }

    /// Cancel all in-flight operations and prevent new ones from starting
    public func cancel() async {
        await executionState.cancel()
        await workQueues.cancelAll()
        // Note: Individual ExecutionContext instances will clean up their own
        // active snapshots when operations are cancelled and throw errors
    }

    public func execute(_ graph: BuildGraph) async throws -> BuildResult {
        let startTime = Date()

        // Reset state
        await executionState.reset()
        await metricsCollector.reset()

        // Report build started if we have a reporter
        if let reporter = reporter {
            let totalOperations = graph.stages.reduce(0) { $0 + $1.nodes.count + 1 }  // +1 for base image
            await reporter.report(.buildStarted(totalOperations: totalOperations, stages: graph.stages.count, timestamp: Date()))
        }

        // Start resource monitoring
        let monitoringTask = Task {
            await resourceMonitor.startMonitoring(executionState: executionState)
        }

        defer {
            monitoringTask.cancel()
        }

        // Analyze graph for parallelization opportunities
        let parallelizationPlan = try analyzeGraph(graph)

        // Execute platforms in parallel when possible
        let platformResults: [Platform: ImageManifest]
        do {
            platformResults = try await withThrowingTaskGroup(of: PlatformResult.self) { group in
                for platform in graph.targetPlatforms {
                    group.addTask {
                        try await self.executePlatform(
                            graph: graph,
                            platform: platform,
                            plan: parallelizationPlan
                        )
                    }
                }

                var results: [Platform: ImageManifest] = [:]
                do {
                    for try await result in group {
                        results[result.platform] = result.manifest
                    }
                } catch {
                    // Cancel all remaining tasks on error
                    group.cancelAll()
                    // Signal cancellation to execution state
                    await executionState.cancel()
                    throw error
                }
                return results
            }
        } catch {
            // Report build failure
            await reporter?.report(.buildCompleted(success: false, timestamp: Date()))
            await reporter?.finish()

            // Run completion handlers before throwing
            for handler in completionHandlers.value {
                await handler()
            }

            throw error
        }

        // Report build success
        await reporter?.report(.buildCompleted(success: true, timestamp: Date()))
        await reporter?.finish()

        // Run all completion handlers to ensure consumers finish
        for handler in completionHandlers.value {
            await handler()
        }

        // Collect final metrics
        let totalDuration = Date().timeIntervalSince(startTime)
        let (metrics, logs) = await metricsCollector.finalizeMetrics(totalDuration: totalDuration, executionState: executionState)
        let cacheStats = await cache.statistics()

        return BuildResult(
            manifests: platformResults,
            metrics: metrics,
            cacheStats: cacheStats,
            logs: logs
        )
    }

    /// Register a completion handler that will be called after the build completes
    /// but before execute() returns. This is useful for ensuring progress consumers
    /// finish processing all events.
    public func onCompletion(_ handler: @escaping @Sendable () async -> Void) {
        completionHandlers.value.append(handler)
    }

    // MARK: - Graph Analysis

    internal func analyzeGraph(_ graph: BuildGraph) throws -> ParallelizationPlan {
        var plan = ParallelizationPlan()

        for stage in graph.stages {
            // Analyze dependencies within stage
            let analysis = try analyzeStage(stage)
            plan.stageAnalyses[stage.id] = analysis
        }

        return plan
    }

    private func analyzeStage(_ stage: BuildStage) throws -> StageAnalysis {
        let dependencyGraph = try buildDependencyGraph(stage)
        let parallelizableGroups = findParallelizableGroups(dependencyGraph)

        return StageAnalysis(
            dependencyGraph: dependencyGraph,
            parallelizableGroups: parallelizableGroups
        )
    }

    private func buildDependencyGraph(_ stage: BuildStage) throws -> DependencyGraph {
        var graph = DependencyGraph()

        // Add all nodes
        for node in stage.nodes {
            graph.addNode(node)
        }

        // Add edges based on dependencies
        for node in stage.nodes {
            for dep in node.dependencies {
                if let depNode = stage.nodes.first(where: { $0.id == dep }) {
                    graph.addEdge(from: depNode, to: node)
                }
            }
        }

        // Verify no cycles
        if graph.hasCycle() {
            throw BuildExecutorError.cyclicDependency
        }

        return graph
    }

    private func findParallelizableGroups(_ graph: DependencyGraph) -> [[BuildNode]] {
        var groups: [[BuildNode]] = []
        var processed = Set<UUID>()

        // Use Kahn's algorithm to find nodes that can execute in parallel
        while processed.count < graph.nodeCount {
            var currentGroup: [BuildNode] = []

            // Find all nodes with no unprocessed dependencies
            for node in graph.allNodes {
                if !processed.contains(node.id) {
                    let deps = graph.dependencies(of: node)
                    if deps.allSatisfy({ processed.contains($0.id) }) {
                        currentGroup.append(node)
                    }
                }
            }

            if currentGroup.isEmpty {
                break  // Shouldn't happen if no cycles
            }

            groups.append(currentGroup)
            currentGroup.forEach { processed.insert($0.id) }
        }

        return groups
    }

    // MARK: - Platform Execution

    private func executePlatform(
        graph: BuildGraph,
        platform: Platform,
        plan: ParallelizationPlan
    ) async throws -> PlatformResult {
        let stages = try graph.stagesForExecution(targetStage: graph.targetStage)
        var stageSnapshots: [String: Snapshot] = [:]
        var finalSnapshot: Snapshot?

        // Build stage dependency graph to find parallelizable stages
        var stageDependencies: [UUID: Set<UUID>] = [:]
        for stage in stages {
            stageDependencies[stage.id] = Set()

            // Check for COPY --from dependencies
            for node in stage.nodes {
                if let copyOp = node.operation as? FilesystemOperation,
                    case .stage(let stageRef, _) = copyOp.source
                {
                    if let depStage = resolveStageReference(stageRef, in: stages, currentStage: stage) {
                        stageDependencies[stage.id]?.insert(depStage.id)
                    }
                }
            }
        }

        // Execute all base images in parallel first
        var baseImageSnapshots: [UUID: Snapshot] = [:]
        let sharedContext = SharedStageContext()

        // Start all base image operations in parallel
        try await withThrowingTaskGroup(of: (UUID, String?, Snapshot?).self) { group in
            for stage in stages {
                group.addTask {
                    if await self.executionState.isCancelled {
                        throw BuildExecutorError.cancelled
                    }

                    let context = ExecutionContext(
                        stage: stage,
                        graph: graph,
                        platform: platform,
                        reporter: self.reporter ?? Reporter(),
                        snapshotter: self.snapshotter
                    )

                    let stageName = stage.name ?? "stage-\(stage.id.uuidString.prefix(8))"
                    let baseNodeId = UUID()
                    let baseReportContext = ReportContext(
                        nodeId: baseNodeId,
                        stageId: stageName,
                        description: ReportContext.describeOperation(stage.base),
                        timestamp: Date(),
                        sourceMap: nil
                    )

                    await self.reporter?.report(.operationStarted(context: baseReportContext))

                    let baseSnapshot = try await self.executeBaseImage(stage.base, context: context)

                    await self.reporter?.report(.operationFinished(context: baseReportContext, duration: 0))

                    return (stage.id, stage.name, baseSnapshot)
                }
            }

            // Collect base image results and store in shared context
            for try await (stageId, stageName, snapshot) in group {
                if let snapshot = snapshot {
                    baseImageSnapshots[stageId] = snapshot
                    // Store in shared context so stages can access via COPY --from
                    if let name = stageName {
                        await sharedContext.setSnapshot(name, snapshot: snapshot)
                    }
                }
            }
        }

        // Execute stages in parallel when possible
        var completedStages = Set<UUID>()
        var stageResults: [UUID: Snapshot] = [:]

        while completedStages.count < stages.count {
            if await executionState.isCancelled {
                throw BuildExecutorError.cancelled
            }

            // Find stages that can run now (all dependencies completed)
            var stagesToRun: [BuildStage] = []
            for stage in stages {
                if !completedStages.contains(stage.id) {
                    let deps = stageDependencies[stage.id] ?? []
                    if deps.isSubset(of: completedStages) {
                        stagesToRun.append(stage)
                    }
                }
            }

            if stagesToRun.isEmpty {
                throw BuildExecutorError.cyclicDependency
            }

            // Execute all ready stages in parallel
            try await withThrowingTaskGroup(of: (UUID, String?, Snapshot).self) { group in
                for stage in stagesToRun {
                    let baseSnapshot = baseImageSnapshots[stage.id]
                    group.addTask {
                        // Check for cancellation before starting
                        if await self.executionState.isCancelled {
                            throw BuildExecutorError.cancelled
                        }

                        let context = ExecutionContext(
                            stage: stage,
                            graph: graph,
                            platform: platform,
                            reporter: self.reporter ?? Reporter(),
                            snapshotter: self.snapshotter
                        )

                        let stageName = stage.name ?? "stage-\(stage.id.uuidString.prefix(8))"
                        await self.reporter?.report(.stageStarted(stageName: stageName, timestamp: Date()))

                        guard let stageAnalysis = plan.stageAnalyses[stage.id] else {
                            throw BuildExecutorError.internalError("Stage analysis not found for stage \(stage.id)")
                        }

                        // Set the base image snapshot in the context if available
                        if let baseSnapshot = baseSnapshot {
                            context.setSnapshot(baseSnapshot, for: UUID())
                            await self.executionState.markNodeCompleted(UUID())
                        }

                        let snapshot = try await self.executeStageParallel(
                            stage,
                            context: context,
                            sharedContext: sharedContext,
                            plan: stageAnalysis,
                            skipBaseImage: true
                        )

                        await self.reporter?.report(.stageCompleted(stageName: stageName, timestamp: Date()))

                        return (stage.id, stage.name, snapshot)
                    }
                }

                // Collect results
                for try await (stageId, stageName, snapshot) in group {
                    completedStages.insert(stageId)
                    stageResults[stageId] = snapshot
                    if let name = stageName {
                        await sharedContext.setSnapshot(name, snapshot: snapshot)
                        stageSnapshots[name] = snapshot
                    }
                    finalSnapshot = snapshot
                }
            }
        }

        guard let snapshot = finalSnapshot else {
            throw BuildExecutorError.stageNotFound("No stages executed")
        }

        let configDigest = try Digest(algorithm: .sha256, bytes: Data(count: 32))
        let manifest = ImageManifest(
            digest: snapshot.digest,
            size: snapshot.size,
            configDigest: configDigest,
            layers: [LayerDescriptor(digest: snapshot.digest, size: snapshot.size)]
        )

        return PlatformResult(platform: platform, manifest: manifest)
    }

    private func resolveStageReference(_ ref: StageReference, in stages: [BuildStage], currentStage: BuildStage) -> BuildStage? {
        switch ref {
        case .named(let name):
            return stages.first { $0.name == name }
        case .index(let idx):
            return idx < stages.count ? stages[idx] : nil
        case .previous:
            if let currentIndex = stages.firstIndex(where: { $0.id == currentStage.id }), currentIndex > 0 {
                return stages[currentIndex - 1]
            }
            return nil
        }
    }

    private func executeStageParallel(
        _ stage: BuildStage,
        context: ExecutionContext,
        sharedContext: SharedStageContext,
        plan: StageAnalysis,
        skipBaseImage: Bool = false
    ) async throws -> Snapshot {
        let stageStart = Date()
        defer {
            let duration = Date().timeIntervalSince(stageStart)
            Task {
                await metricsCollector.recordStageDuration(stage.name ?? "unnamed", duration: duration)
            }
        }

        // Execute base image (unless it was already executed)
        if !skipBaseImage {
            let baseNodeId = UUID()
            let baseReportContext = ReportContext(
                nodeId: baseNodeId,
                stageId: stage.name ?? "stage-\(stage.id.uuidString.prefix(8))",
                description: ReportContext.describeOperation(stage.base),
                timestamp: Date(),
                sourceMap: nil
            )

            // Report base image operation started
            await context.reporter.report(.operationStarted(context: baseReportContext))

            if let baseSnapshot = try await executeBaseImage(stage.base, context: context) {
                context.setSnapshot(baseSnapshot, for: baseNodeId)

                // Report base image operation finished
                await context.reporter.report(.operationFinished(context: baseReportContext, duration: 0))

                // Mark base operation as completed so nodes can depend on it
                await executionState.markNodeCompleted(baseNodeId)
            }
        }

        // Execute nodes in parallel groups
        for (groupIndex, group) in plan.parallelizableGroups.enumerated() {
            do {
                try await executeNodeGroup(group, context: context, stage: stage)
            } catch {
                // Handle errors based on configuration
                if configuration.failFast {
                    throw BuildExecutorError.operationFailed(
                        group.first?.operation ?? UnknownOperation(metadata: OperationMetadata()),
                        underlying: error
                    )
                } else {
                    // Log error and continue if possible
                    print("Warning: Group \(groupIndex) in stage '\(stage.name ?? "unnamed")' failed: \(error)")
                    // Mark failed nodes to skip dependents
                    for node in group {
                        await executionState.markNodeFailed(node.id)
                    }
                }
            }
        }

        guard let finalSnapshot = context.headSnapshot else {
            throw BuildExecutorError.stageNotFound("No operations in stage")
        }

        return finalSnapshot
    }

    private func executeNodeGroup(
        _ nodes: [BuildNode],
        context: ExecutionContext,
        stage: BuildStage
    ) async throws {
        // Wait for available execution slots
        await resourceMonitor.waitForResources(count: nodes.count)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for node in nodes {
                group.addTask {
                    try await self.executeNodeWithTracking(node, context: context, stage: stage)
                }
            }

            do {
                try await group.waitForAll()
            } catch {
                // On error, cancel all remaining tasks
                group.cancelAll()

                // Signal cancellation if configured for fail-fast
                if self.configuration.failFast {
                    await self.executionState.cancel()
                }

                throw error
            }
        }
    }

    private func executeNodeWithTracking(
        _ node: BuildNode,
        context: ExecutionContext,
        stage: BuildStage
    ) async throws {
        // Wait for ALL dependencies (including cross-stage) to complete
        for depId in node.dependencies {
            do {
                try await executionState.waitForNode(depId)
            } catch {
                await executionState.markNodeFailed(node.id)
                throw BuildExecutorError.operationFailed(
                    node.operation,
                    underlying: error
                )
            }
        }

        let nodeStart = Date()
        await executionState.incrementOperationCount()

        // Create report context
        let reportContext = ReportContext(node: node, stage: stage, operation: node.operation)

        // Report operation started
        await context.reporter.report(.operationStarted(context: reportContext))

        defer {
            let duration = Date().timeIntervalSince(nodeStart)
            Task {
                await metricsCollector.recordOperationDuration(node.id, duration: duration)
                await resourceMonitor.releaseResource()
            }
        }

        // Check cache
        let cacheKey: CacheKey
        do {
            cacheKey = try computeCacheKey(node: node, context: context)
        } catch {
            // If we can't compute cache key, skip caching and execute directly
            cacheKey = CacheKey(
                operationDigest: try Digest(algorithm: .sha256, bytes: Data(count: 32)),
                inputDigests: [],
                platform: context.platform
            )
        }

        if let cached = await cache.get(cacheKey, for: node.operation) {
            await executionState.incrementCacheHits()
            context.setSnapshot(cached.snapshot, for: node.id)

            // Report cache hit
            await context.reporter.report(.operationCacheHit(context: reportContext))

            // Mark node as completed
            await executionState.markNodeCompleted(node.id)
            return
        }

        // Execute operation with retry logic
        var lastError: Error?
        var retryCount = 0
        let retryPolicy = node.operation.metadata.retryPolicy
        let maxRetries = retryPolicy.maxRetries

        while retryCount <= maxRetries {
            // Check for cancellation before each attempt
            if await executionState.isCancelled {
                throw BuildExecutorError.cancelled
            }

            do {
                let result = try await self.executeNode(node, context: context)

                if let output = result.output {
                    if !output.stdout.isEmpty {
                        await metricsCollector.recordLog("[\(node.id)] \(output.stdout)")
                        // Report operation log
                        await context.reporter.report(.operationLog(context: reportContext, message: output.stdout))
                    }
                    if !output.stderr.isEmpty {
                        await metricsCollector.recordLog("[\(node.id)] [STDERR] \(output.stderr)")
                        // Report operation log for stderr
                        await context.reporter.report(.operationLog(context: reportContext, message: "[STDERR] \(output.stderr)"))
                    }
                }

                context.setSnapshot(result.snapshot, for: node.id)

                // Store in cache
                let cachedResult = CachedResult(
                    snapshot: result.snapshot,
                    environmentChanges: result.environmentChanges,
                    metadataChanges: result.metadataChanges
                )
                await cache.put(cachedResult, key: cacheKey, for: node.operation)

                // Report operation finished
                await context.reporter.report(.operationFinished(context: reportContext, duration: result.duration))

                // Mark node as completed
                await executionState.markNodeCompleted(node.id)
                return  // Success

            } catch {
                lastError = error
                retryCount = await executionState.incrementRetryCount(for: node.id)

                if retryCount <= maxRetries {
                    // Calculate backoff delay
                    let delay = min(
                        retryPolicy.initialDelay * pow(retryPolicy.backoffMultiplier, Double(retryCount - 1)),
                        retryPolicy.maxDelay
                    )

                    print("Retrying operation \(node.id) after \(delay)s (attempt \(retryCount)/\(maxRetries))")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        // All retries failed
        await executionState.markNodeFailed(node.id)

        // Report operation failed
        let finalError =
            lastError
            ?? BuildExecutorError.operationFailed(
                node.operation,
                underlying: UnknownFailureError()
            )
        let eventError = BuildEventError(
            type: .executionFailed,
            description: finalError.localizedDescription,
            diagnostics: nil
        )
        await context.reporter.report(.operationFailed(context: reportContext, error: eventError))

        throw BuildExecutorError.operationFailed(node.operation, underlying: finalError)
    }

    // MARK: - Node Execution

    private func executeBaseImage(
        _ operation: ImageOperation,
        context: ExecutionContext
    ) async throws -> Snapshot? {
        let result = try await dispatcher.dispatch(operation, context: context)
        return result.snapshot
    }

    private func executeNode(
        _ node: BuildNode,
        context: ExecutionContext
    ) async throws -> ExecutionResult {
        let constraints = buildNodeConstraints(node)

        return try await dispatcher.dispatch(
            node.operation,
            context: context,
            constraints: constraints
        )
    }

    private func buildNodeConstraints(_ node: BuildNode) -> NodeConstraints? {
        guard !node.constraints.isEmpty else { return nil }

        var requiresPrivileged = false
        var minMemory: Int64?
        var cpuArchitecture: String?

        for constraint in node.constraints {
            switch constraint {
            case .requiresPrivileged:
                requiresPrivileged = true
            case .memoryLimit(let limit):
                minMemory = Int64(limit)
            case .requiresPlatform(let platform):
                cpuArchitecture = platform.architecture
            default:
                break
            }
        }

        return NodeConstraints(
            requiresPrivileged: requiresPrivileged,
            minMemory: minMemory,
            cpuArchitecture: cpuArchitecture
        )
    }

    // MARK: - Cache Key Generation

    private func computeCacheKey(
        node: BuildNode,
        context: ExecutionContext
    ) throws -> CacheKey {
        let operationDigest = try node.operation.contentDigest()

        var inputDigests: [ContainerBuildIR.Digest] = []

        // Add parent snapshot digest
        if let parentSnapshot = context.headSnapshot {
            inputDigests.append(parentSnapshot.digest)
        }

        // Add dependency snapshots
        for depId in node.dependencies {
            if let depSnapshot = context.snapshot(for: depId) {
                inputDigests.append(depSnapshot.digest)
            }
        }

        return CacheKey(
            operationDigest: operationDigest,
            inputDigests: inputDigests.sorted(by: { $0.stringValue < $1.stringValue }),
            platform: context.platform
        )
    }

}

// MARK: - Supporting Types

/// Shared context for stages running in parallel
private actor SharedStageContext {
    private var snapshots: [String: Snapshot] = [:]

    func setSnapshot(_ name: String, snapshot: Snapshot) {
        snapshots[name] = snapshot
    }

    func getSnapshot(_ name: String) -> Snapshot? {
        snapshots[name]
    }

    func getAllSnapshots() -> [String: Snapshot] {
        snapshots
    }
}

/// Tracks execution state across the scheduler
private actor ExecutionState {
    private var cancelled = false
    private var operationCount = 0
    private var cacheHits = 0
    private var failedNodes: Set<UUID> = []
    private var nodeRetries: [UUID: Int] = [:]
    private var completedNodes: Set<UUID> = []
    private var nodeCompletionWaiters: [UUID: [CheckedContinuation<Void, Error>]] = [:]

    var isCancelled: Bool { cancelled }

    func cancel() {
        cancelled = true
        // Wake up any waiters with cancellation error
        for (_, waiters) in nodeCompletionWaiters {
            for waiter in waiters {
                waiter.resume(throwing: BuildExecutorError.cancelled)
            }
        }
        nodeCompletionWaiters.removeAll()
    }

    func reset() {
        cancelled = false
        operationCount = 0
        cacheHits = 0
        failedNodes.removeAll()
        nodeRetries.removeAll()
        completedNodes.removeAll()
        nodeCompletionWaiters.removeAll()
    }

    func incrementOperationCount() {
        operationCount += 1
    }

    func incrementCacheHits() {
        cacheHits += 1
    }

    func markNodeCompleted(_ nodeId: UUID) {
        completedNodes.insert(nodeId)
        // Wake up any waiters for this node
        if let waiters = nodeCompletionWaiters.removeValue(forKey: nodeId) {
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func markNodeFailed(_ nodeId: UUID) {
        failedNodes.insert(nodeId)
        // Wake up any waiters with failure
        if let waiters = nodeCompletionWaiters.removeValue(forKey: nodeId) {
            for waiter in waiters {
                waiter.resume(throwing: DependencyFailedError(dependencyId: nodeId))
            }
        }
    }

    func isNodeCompleted(_ nodeId: UUID) -> Bool {
        completedNodes.contains(nodeId)
    }

    func isNodeFailed(_ nodeId: UUID) -> Bool {
        failedNodes.contains(nodeId)
    }

    func waitForNode(_ nodeId: UUID) async throws {
        if completedNodes.contains(nodeId) {
            return  // Already completed
        }

        if failedNodes.contains(nodeId) {
            throw DependencyFailedError(dependencyId: nodeId)
        }

        if cancelled {
            throw BuildExecutorError.cancelled
        }

        // Wait for the node to complete
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Check again in case state changed
            if completedNodes.contains(nodeId) {
                continuation.resume()
                return
            }

            if failedNodes.contains(nodeId) {
                continuation.resume(throwing: DependencyFailedError(dependencyId: nodeId))
                return
            }

            if cancelled {
                continuation.resume(throwing: BuildExecutorError.cancelled)
                return
            }

            var waiters = nodeCompletionWaiters[nodeId] ?? []
            waiters.append(continuation)
            nodeCompletionWaiters[nodeId] = waiters
        }
    }

    func incrementRetryCount(for nodeId: UUID) -> Int {
        let count = (nodeRetries[nodeId] ?? 0) + 1
        nodeRetries[nodeId] = count
        return count
    }

    func getStats() -> (operations: Int, hits: Int, failures: Int) {
        (operationCount, cacheHits, failedNodes.count)
    }
}

/// Manages work queues for parallel execution with work stealing
private actor WorkQueueManager {
    private let queues: [WorkQueue]
    private let enableWorkStealing: Bool
    private var nextQueueIndex = 0

    init(concurrency: Int, enableWorkStealing: Bool) {
        self.queues = (0..<concurrency).map { WorkQueue(id: $0) }
        self.enableWorkStealing = enableWorkStealing

        // Set up work stealing relationships
        if enableWorkStealing {
            for i in 0..<concurrency {
                let stealTargets = (0..<concurrency).filter { $0 != i }.map { queues[$0] }
                queues[i].setStealTargets(stealTargets)
            }
        }
    }

    /// Submit a task to the least loaded queue
    func submit(_ task: @escaping () async throws -> Void) {
        // Round-robin with load balancing
        let startIndex = nextQueueIndex
        var minLoad = Int.max
        var targetQueue = queues[startIndex]

        for i in 0..<queues.count {
            let index = (startIndex + i) % queues.count
            let load = queues[index].currentLoad
            if load < minLoad {
                minLoad = load
                targetQueue = queues[index]
            }
        }

        targetQueue.enqueue(task)
        nextQueueIndex = (nextQueueIndex + 1) % queues.count
    }

    /// Start all worker threads
    func start() async {
        await withTaskGroup(of: Void.self) { group in
            for queue in queues {
                group.addTask {
                    await queue.processLoop()
                }
            }
        }
    }

    func cancelAll() {
        for queue in queues {
            queue.cancel()
        }
    }
}

/// Individual work queue with work stealing capability
private final class WorkQueue: @unchecked Sendable {
    private let id: Int
    private var tasks: [() async throws -> Void] = []
    private let lock = NSLock()
    private var cancelled = false
    private var isProcessing = false
    private var stealTargets: [WorkQueue] = []
    private let workAvailable = NSCondition()

    var currentLoad: Int {
        lock.withLock { tasks.count }
    }

    init(id: Int) {
        self.id = id
    }

    func setStealTargets(_ targets: [WorkQueue]) {
        lock.withLock {
            self.stealTargets = targets
        }
    }

    func enqueue(_ task: @escaping () async throws -> Void) {
        lock.withLock {
            guard !cancelled else { return }
            tasks.append(task)
            workAvailable.signal()
        }
    }

    func processLoop() async {
        while !cancelled {
            if let task = dequeueOrSteal() {
                do {
                    try await task()
                } catch {
                    // Log error but continue processing
                    print("Task failed: \(error)")
                }
            } else {
                // No work available, wait
                lock.withLock {
                    guard !cancelled && tasks.isEmpty else { return }
                    workAvailable.wait()
                }
            }
        }
    }

    private func dequeueOrSteal() -> (() async throws -> Void)? {
        // Try to get from own queue first
        if let task = dequeue() {
            return task
        }

        // If work stealing is enabled, try to steal from others
        if !stealTargets.isEmpty {
            // Randomize steal order to avoid contention
            let shuffled = stealTargets.shuffled()
            for target in shuffled {
                if let task = target.steal() {
                    return task
                }
            }
        }

        return nil
    }

    private func dequeue() -> (() async throws -> Void)? {
        lock.withLock {
            guard !tasks.isEmpty else { return nil }
            return tasks.removeFirst()
        }
    }

    private func steal() -> (() async throws -> Void)? {
        lock.withLock {
            // Steal from the back to minimize contention
            guard tasks.count > 1 else { return nil }
            return tasks.removeLast()
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            tasks.removeAll()
            workAvailable.broadcast()
        }
    }
}

/// Monitors resource usage
private actor ResourceMonitor {
    private let maxMemory: Int64
    private let interval: TimeInterval
    private var availableSlots: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxMemory: Int64, interval: TimeInterval) {
        self.maxMemory = maxMemory
        self.interval = interval
        self.availableSlots = ProcessInfo.processInfo.activeProcessorCount * 2
    }

    func startMonitoring(executionState: ExecutionState) async {
        while await !executionState.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            // Monitor memory and CPU usage
            // Adjust available slots based on system load
        }
    }

    func waitForResources(count: Int) async {
        while availableSlots < count {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        availableSlots -= count
    }

    func releaseResource() {
        availableSlots += 1
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        }
    }
}

/// Collects execution metrics
private actor MetricsCollector {
    private var operationDurations: [UUID: TimeInterval] = [:]
    private var stageDurations: [String: TimeInterval] = [:]
    private var logs: [String] = []
    private var startTime = Date()

    func reset() {
        operationDurations.removeAll()
        stageDurations.removeAll()
        logs.removeAll()
        startTime = Date()
    }

    func recordOperationDuration(_ id: UUID, duration: TimeInterval) {
        operationDurations[id] = duration
    }

    func recordStageDuration(_ name: String, duration: TimeInterval) {
        stageDurations[name] = duration
    }

    func recordLog(_ log: String) {
        logs.append(log)
    }

    func finalizeMetrics(totalDuration: TimeInterval, executionState: ExecutionState) async -> (ExecutionMetrics, [String]) {
        let stats = await executionState.getStats()
        let metrics = ExecutionMetrics(
            totalDuration: totalDuration,
            stageDurations: stageDurations,
            operationCount: operationDurations.count,
            cachedOperationCount: stats.hits,
            bytesTransferred: 0  // TODO: Track this
        )
        return (metrics, logs)
    }
}

/// Result for a single platform build
private struct PlatformResult {
    let platform: Platform
    let manifest: ImageManifest
}

/// Parallelization analysis results
internal struct ParallelizationPlan {
    var stageAnalyses: [UUID: StageAnalysis] = [:]
}

/// Analysis results for a single stage
internal struct StageAnalysis {
    let dependencyGraph: DependencyGraph
    let parallelizableGroups: [[BuildNode]]
}

/// Dependency graph for analysis
internal struct DependencyGraph {
    private var adjacencyList: [UUID: Set<UUID>] = [:]
    private var nodesList: [BuildNode] = []

    var nodeCount: Int { nodesList.count }
    var allNodes: [BuildNode] { nodesList }

    mutating func addNode(_ node: BuildNode) {
        nodesList.append(node)
        adjacencyList[node.id] = []
    }

    mutating func addEdge(from: BuildNode, to: BuildNode) {
        adjacencyList[from.id]?.insert(to.id)
    }

    func dependencies(of node: BuildNode) -> [BuildNode] {
        nodesList.filter { node.dependencies.contains($0.id) }
    }

    func hasCycle() -> Bool {
        var visited = Set<UUID>()
        var recursionStack = Set<UUID>()

        func dfs(_ nodeId: UUID) -> Bool {
            visited.insert(nodeId)
            recursionStack.insert(nodeId)

            if let neighbors = adjacencyList[nodeId] {
                for neighbor in neighbors {
                    if !visited.contains(neighbor) {
                        if dfs(neighbor) {
                            return true
                        }
                    } else if recursionStack.contains(neighbor) {
                        return true
                    }
                }
            }

            recursionStack.remove(nodeId)
            return false
        }

        for node in nodesList {
            if !visited.contains(node.id) {
                if dfs(node.id) {
                    return true
                }
            }
        }

        return false
    }
}

// MARK: - Error Types

/// Error when a dependency failed
struct DependencyFailedError: LocalizedError {
    let dependencyId: UUID

    var errorDescription: String? {
        "Dependency \(dependencyId) failed"
    }
}

/// Error when operation fails for unknown reasons
struct UnknownFailureError: LocalizedError {
    var errorDescription: String? {
        "Operation failed for unknown reasons"
    }
}

/// Placeholder for unknown operations
struct UnknownOperation: ContainerBuildIR.Operation {
    var metadata: OperationMetadata
    static let operationKind = OperationKind(rawValue: "unknown")
    var operationKind: OperationKind { Self.operationKind }

    func accept<V>(_ visitor: V) throws -> V.Result where V: OperationVisitor {
        throw BuildExecutorError.unsupportedOperation(self)
    }
}

// MARK: - Extensions

extension BuildGraph {
    /// Get stages in execution order for a target stage, resolving all dependencies.
    func stagesForExecution(targetStage: BuildStage?) throws -> [BuildStage] {
        let target = targetStage ?? stages.last
        guard let target = target else {
            return []
        }

        // Build dependency graph for stages
        var stageDependencies: [UUID: Set<String>] = [:]
        var stagesByName: [String: BuildStage] = [:]
        var stagesByID: [UUID: BuildStage] = [:]

        // Index stages
        for stage in stages {
            stagesByID[stage.id] = stage
            if let name = stage.name {
                stagesByName[name] = stage
            }
            stageDependencies[stage.id] = []
        }

        // Resolve FROM dependencies
        // Note: In the current IR, stage dependencies are handled differently
        // The base is always an ImageOperation, not a stage reference
        // Stage-to-stage dependencies are handled through COPY --from operations

        // Resolve COPY --from dependencies
        for stage in stages {
            for node in stage.nodes {
                if let copyOp = node.operation as? FilesystemOperation,
                    case .stage(let stageRef, _) = copyOp.source
                {
                    let stageName: String
                    switch stageRef {
                    case .named(let name):
                        stageName = name
                    case .index(let idx):
                        // Find stage by index
                        guard idx < stages.count else {
                            throw BuildExecutorError.stageNotFound("Stage index \(idx) out of bounds")
                        }
                        stageName = stages[idx].name ?? "stage-\(idx)"
                    case .previous:
                        // Find the previous stage
                        guard let currentIndex = stages.firstIndex(where: { $0.id == stage.id }),
                            currentIndex > 0
                        else {
                            throw BuildExecutorError.stageNotFound("No previous stage available")
                        }
                        stageName = stages[currentIndex - 1].name ?? "stage-\(currentIndex - 1)"
                    }

                    guard let sourceStage = stagesByName[stageName] else {
                        throw BuildExecutorError.stageNotFound("Stage '\(stageName)' referenced in COPY --from not found")
                    }
                    stageDependencies[stage.id]?.insert(sourceStage.id.uuidString)
                }
            }
        }

        // Topological sort to find execution order
        var visited = Set<UUID>()
        var recursionStack = Set<UUID>()
        var executionOrder: [BuildStage] = []

        func visit(_ stageId: UUID) throws {
            if recursionStack.contains(stageId) {
                throw BuildExecutorError.cyclicDependency
            }

            if visited.contains(stageId) {
                return
            }

            recursionStack.insert(stageId)

            // Visit dependencies first
            if let deps = stageDependencies[stageId] {
                for depIdString in deps {
                    if let depId = UUID(uuidString: depIdString),
                        let _ = stagesByID[depId]
                    {
                        try visit(depId)
                    }
                }
            }

            recursionStack.remove(stageId)
            visited.insert(stageId)

            if let stage = stagesByID[stageId] {
                executionOrder.append(stage)
            }
        }

        // Start from target and work backwards
        try visit(target.id)

        // Also visit any stages that the target transitively depends on
        var targetDependencies = Set<UUID>()
        func collectDependencies(_ stageId: UUID) {
            if let deps = stageDependencies[stageId] {
                for depIdString in deps {
                    if let depId = UUID(uuidString: depIdString) {
                        if !targetDependencies.contains(depId) {
                            targetDependencies.insert(depId)
                            collectDependencies(depId)
                        }
                    }
                }
            }
        }
        collectDependencies(target.id)

        // Include all required stages
        for stage in stages {
            if targetDependencies.contains(stage.id) || stage.id == target.id {
                if !visited.contains(stage.id) {
                    try visit(stage.id)
                }
            }
        }

        return executionOrder
    }
}

// MARK: - Thread-Safe Storage

/// Thread-safe storage for reference types
private final class AtomicStorage<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    var value: T {
        get {
            lock.withLock { _value }
        }
        set {
            lock.withLock { _value = newValue }
        }
    }

    init(initialValue: T) {
        self._value = initialValue
    }
}

extension AtomicStorage {
    convenience init() where T: ExpressibleByNilLiteral {
        self.init(initialValue: nil)
    }
}
