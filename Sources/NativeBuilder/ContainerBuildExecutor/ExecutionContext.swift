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

import ContainerBuildIR
import ContainerBuildReporting
import ContainerBuildSnapshotter
import ContainerizationOCI
import Foundation

/// Carries execution state through operation execution.
///
/// The context maintains the current state of the build, including filesystem
/// snapshots, environment variables, and other mutable state that operations
/// may read or modify.
public final class ExecutionContext: @unchecked Sendable {
    /// The current build stage being executed.
    public let stage: BuildStage

    /// The complete build graph.
    public let graph: BuildGraph

    /// The target platform for this execution.
    public let platform: Platform

    /// Progress reporter for build events.
    public let reporter: Reporter

    /// The snapshotter for managing filesystem snapshots.
    public let snapshotter: any Snapshotter

    /// Current environment variables.
    private var _environment: Environment

    /// Current working directory.
    private var _workingDirectory: String

    /// Current user.
    private var _user: ContainerBuildIR.User?

    /// Image configuration being built.
    private var _imageConfig: OCIImageConfig

    /// Snapshots for each executed node.
    private var _snapshots: [UUID: Snapshot]

    /// Currently active (prepared but not committed) snapshots for cleanup.
    private var _activeSnapshots: [UUID: Snapshot]

    /// Head (most recent committed) snapshot for this context.
    private var _headSnapshot: Snapshot?

    /// Lock for thread-safe access.
    private let lock = NSLock()

    /// Serialize filesystem mutations within this context.
    /// Ensures prepare → body → commit happens one-at-a-time per context to avoid
    /// divergent snapshot branches when multiple FS-mutating operations run in parallel.
    private let fsSemaphore = AsyncSemaphore(value: 1)

    public init(
        stage: BuildStage,
        graph: BuildGraph,
        platform: Platform,
        reporter: Reporter,
        snapshotter: any Snapshotter,
        baseEnvironment: Environment = .init(),
        baseConfig: OCIImageConfig? = nil
    ) {
        self.stage = stage
        self.graph = graph
        self.platform = platform
        self.reporter = reporter
        self.snapshotter = snapshotter
        self._environment = baseEnvironment
        self._workingDirectory = "/"
        self._user = nil
        self._imageConfig = baseConfig ?? OCIImageConfig(platform: platform)
        self._snapshots = [:]
        self._activeSnapshots = [:]
        self._headSnapshot = nil
    }

    deinit {
        // Clean up any remaining active snapshots
        // Note: This is a best-effort cleanup since deinit can't be async
        // The proper cleanup should happen in the executor error handling
        if !_activeSnapshots.isEmpty {
            // Log warning about unclean shutdown
            print("Warning: ExecutionContext deallocated with \(_activeSnapshots.count) active snapshots")
        }
    }

    /// Get the current environment.
    public var environment: Environment {
        lock.withLock { _environment }
    }

    /// Update the environment.
    public func updateEnvironment(_ updates: [String: EnvironmentValue]) {
        lock.withLock {
            // Create new environment with updates
            var newVars = _environment.variables
            for (key, value) in updates {
                // Remove existing entries for this key
                newVars.removeAll { $0.key == key }
                // Add new entry
                newVars.append((key: key, value: value))
            }
            _environment = Environment(newVars)
        }
    }

    /// Get the current working directory.
    public var workingDirectory: String {
        lock.withLock { _workingDirectory }
    }

    /// Set the working directory.
    public func setWorkingDirectory(_ path: String) {
        lock.withLock { _workingDirectory = path }
    }

    /// Get the current user.
    public var user: ContainerBuildIR.User? {
        lock.withLock { _user }
    }

    /// Set the current user.
    public func setUser(_ user: ContainerBuildIR.User?) {
        lock.withLock { _user = user }
    }

    /// Get the current image configuration.
    public var imageConfig: OCIImageConfig {
        lock.withLock { _imageConfig }
    }

    /// Update the image configuration.
    public func updateImageConfig(_ updates: (inout OCIImageConfig) -> Void) {
        lock.withLock {
            updates(&_imageConfig)
        }
    }

    /// Get the snapshot for a node.
    public func snapshot(for nodeId: UUID) -> Snapshot? {
        lock.withLock { _snapshots[nodeId] }
    }

    /// Set the snapshot for a node.
    public func setSnapshot(_ snapshot: Snapshot, for nodeId: UUID) {
        lock.withLock {
            _snapshots[nodeId] = snapshot
            _headSnapshot = snapshot
        }
    }

    /// The current head snapshot (last committed snapshot in this context).
    public var headSnapshot: Snapshot? {
        lock.withLock { _headSnapshot }
    }

    /// Create a child context for a nested execution.
    public func childContext(for stage: BuildStage) -> ExecutionContext {
        lock.withLock {
            ExecutionContext(
                stage: stage,
                graph: graph,
                platform: platform,
                reporter: reporter,
                snapshotter: snapshotter,
                baseEnvironment: Environment(_environment.variables),
                baseConfig: _imageConfig
            )
        }
    }

    // MARK: - Snapshotter Integration

    /// Prepare a snapshot for modification by an operation.
    ///
    /// This method handles the snapshotter lifecycle:
    /// 1. Takes a parent snapshot (or creates a base snapshot if none)
    /// 2. Calls snapshotter.prepare() to make it ready for modification
    /// 3. Tracks the prepared snapshot for cleanup if needed
    ///
    /// - Parameter operationId: The UUID of the operation that will modify this snapshot
    /// - Returns: A prepared snapshot ready for modification
    /// - Throws: Any errors from the snapshotter
    public func prepareSnapshot(for operationId: UUID) async throws -> Snapshot {
        let parentCommitted = headSnapshot

        // Always create a new child snapshot that points to the latest committed snapshot (if any).
        // Prepare is responsible for ensuring both the child mountpoint and parent materialization (if needed).
        let tempMountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("child-snapshot", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let snapshotToPrepare: Snapshot
        if let parent = parentCommitted {
            snapshotToPrepare = Snapshot(
                digest: parent.digest,  // initial digest equals base; final digest set at commit
                size: parent.size,
                parent: parent,
                state: .prepared(mountpoint: tempMountPoint)
            )
        } else {
            snapshotToPrepare = Snapshot(
                digest: try Digest(algorithm: .sha256, bytes: Data(count: 32)),  // Empty digest for scratch
                size: 0,
                parent: nil,
                state: .prepared(mountpoint: tempMountPoint)
            )
        }

        // Prepare the snapshot via snapshotter (materializes parent if needed).
        let preparedSnapshot = try await snapshotter.prepare(snapshotToPrepare)

        // Track active snapshot for cleanup
        lock.withLock {
            _activeSnapshots[operationId] = preparedSnapshot
        }

        return preparedSnapshot
    }

    /// Commit a prepared snapshot after an operation completes successfully.
    ///
    /// This method:
    /// 1. Calls snapshotter.commit() to finalize the snapshot
    /// 2. Stores the committed snapshot for the operation
    /// 3. Removes it from active snapshots tracking
    ///
    /// - Parameters:
    ///   - snapshot: The prepared snapshot to commit
    ///   - operationId: The UUID of the operation that modified this snapshot
    /// - Returns: The committed snapshot with final digest and state
    /// - Throws: Any errors from the snapshotter
    public func commitSnapshot(_ snapshot: Snapshot, for operationId: UUID) async throws -> Snapshot {
        let committedSnapshot = try await snapshotter.commit(snapshot)

        lock.withLock {
            // Store committed snapshot
            _snapshots[operationId] = committedSnapshot
            // Update head pointer
            _headSnapshot = committedSnapshot
            // Remove from active tracking
            _activeSnapshots.removeValue(forKey: operationId)
        }

        return committedSnapshot
    }

    /// Clean up a prepared snapshot if an operation fails.
    ///
    /// This method:
    /// 1. Calls snapshotter.remove() to clean up the snapshot
    /// 2. Removes it from active snapshots tracking
    ///
    /// - Parameter operationId: The UUID of the operation that failed
    public func cleanupSnapshot(for operationId: UUID) async {
        let snapshotToCleanup = lock.withLock {
            _activeSnapshots.removeValue(forKey: operationId)
        }

        if let snapshot = snapshotToCleanup {
            do {
                try await snapshotter.remove(snapshot)
            } catch {
                // Log error but don't throw - this is cleanup
                let context = ReportContext(description: "Snapshot cleanup warning")
                await reporter.report(.operationLog(context: context, message: "Failed to cleanup snapshot \(snapshot.id): \(error)"))
            }
        }
    }

    /// Clean up all active snapshots (for context cleanup).
    public func cleanupAllActiveSnapshots() async {
        let activeSnapshots = lock.withLock {
            let snapshots = Array(_activeSnapshots.values)
            _activeSnapshots.removeAll()
            return snapshots
        }

        for snapshot in activeSnapshots {
            do {
                try await snapshotter.remove(snapshot)
            } catch {
                // Log error but continue cleanup
                let context = ReportContext(description: "Snapshot cleanup warning")
                await reporter.report(.operationLog(context: context, message: "Failed to cleanup snapshot \(snapshot.id): \(error)"))
            }
        }
    }

    /// Get the count of active snapshots (for monitoring/debugging).
    public var activeSnapshotCount: Int {
        lock.withLock { _activeSnapshots.count }
    }

    /// Get the count of committed snapshots (for monitoring/debugging).
    public var committedSnapshotCount: Int {
        lock.withLock { _snapshots.count }
    }

    // MARK: - Snapshot helper

    /// Convenience wrapper to prepare, use, and commit a snapshot around a body of work.
    /// - Parameters:
    ///   - base: Optional starting snapshot to prepare. If nil, a new child of the latest committed snapshot is created.
    ///   - body: Async body that performs work against the prepared snapshot.
    /// - Returns: Tuple of (result returned by body, final committed snapshot)
    @discardableResult
    public func withSnapshot<T: Sendable>(startingFrom base: Snapshot? = nil, _ body: @Sendable (Snapshot) async throws -> T) async throws -> (T, Snapshot) {
        try await fsSemaphore.withPermit {
            let operationId = UUID()

            // Prepare snapshot
            let workingSnapshot: Snapshot
            if let base = base {
                // Prepare provided base snapshot and track it as active for cleanup
                let prepared: Snapshot
                switch base.state {
                case .prepared:
                    prepared = base
                default:
                    prepared = try await snapshotter.prepare(base)
                }
                lock.withLock {
                    _activeSnapshots[operationId] = prepared
                }
                workingSnapshot = prepared
            } else {
                workingSnapshot = try await prepareSnapshot(for: operationId)
            }

            do {
                // Execute body work
                let result = try await body(workingSnapshot)

                // Commit and persist
                let finalSnapshot = try await commitSnapshot(workingSnapshot, for: operationId)

                return (result, finalSnapshot)
            } catch {
                // Cleanup on failure then rethrow
                await cleanupSnapshot(for: operationId)
                throw error
            }
        }
    }

    /// Prepare and commit a snapshot from a provided base without performing any body work.
    /// If the base is not already prepared, it will be prepared first.
    /// - Parameter base: The base snapshot to prepare and commit.
    /// - Returns: The committed snapshot.
    public func prepareAndCommit(from base: Snapshot) async throws -> Snapshot {
        try await fsSemaphore.withPermit {
            let operationId = UUID()

            // Prepare if needed and track as active for cleanup
            let working: Snapshot
            switch base.state {
            case .prepared:
                working = base
                lock.withLock { _activeSnapshots[operationId] = working }
            default:
                let prepared = try await snapshotter.prepare(base)
                lock.withLock { _activeSnapshots[operationId] = prepared }
                working = prepared
            }

            do {
                let committed = try await commitSnapshot(working, for: operationId)
                return committed
            } catch {
                await cleanupSnapshot(for: operationId)
                throw error
            }
        }
    }
}

/// OCI image configuration.
///
/// Represents the configuration for an OCI container image.
public struct OCIImageConfig: Sendable {
    /// The platform this image is for.
    public let platform: Platform

    /// Environment variables.
    public var env: [String]

    /// Default command.
    public var cmd: [String]?

    /// Entry point.
    public var entrypoint: [String]?

    /// Working directory.
    public var workingDir: String?

    /// User.
    public var user: String?

    /// Exposed ports.
    public var exposedPorts: Set<String>

    /// Volumes.
    public var volumes: Set<String>

    /// Labels.
    public var labels: [String: String]

    /// Stop signal.
    public var stopSignal: String?

    /// Health check.
    public var healthcheck: Healthcheck?

    public init(
        platform: Platform,
        env: [String] = [],
        cmd: [String]? = nil,
        entrypoint: [String]? = nil,
        workingDir: String? = nil,
        user: String? = nil,
        exposedPorts: Set<String> = [],
        volumes: Set<String> = [],
        labels: [String: String] = [:],
        stopSignal: String? = nil,
        healthcheck: Healthcheck? = nil
    ) {
        self.platform = platform
        self.env = env
        self.cmd = cmd
        self.entrypoint = entrypoint
        self.workingDir = workingDir
        self.user = user
        self.exposedPorts = exposedPorts
        self.volumes = volumes
        self.labels = labels
        self.stopSignal = stopSignal
        self.healthcheck = healthcheck
    }
}

// Helper extension for thread-safe lock usage
extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

// Helper extension for Environment
extension Environment {
    /// Get the value for a key.
    public func get(_ key: String) -> EnvironmentValue? {
        for (k, v) in variables.reversed() {
            if k == key {
                return v
            }
        }
        return nil
    }
}
