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

    /// Lock for thread-safe access.
    private let lock = NSLock()

    public init(
        stage: BuildStage,
        graph: BuildGraph,
        platform: Platform,
        reporter: Reporter,
        baseEnvironment: Environment = .init(),
        baseConfig: OCIImageConfig? = nil
    ) {
        self.stage = stage
        self.graph = graph
        self.platform = platform
        self.reporter = reporter
        self._environment = baseEnvironment
        self._workingDirectory = "/"
        self._user = nil
        self._imageConfig = baseConfig ?? OCIImageConfig(platform: platform)
        self._snapshots = [:]
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
        lock.withLock { _snapshots[nodeId] = snapshot }
    }

    /// Get the latest snapshot (from the most recently executed node).
    public func latestSnapshot() -> Snapshot? {
        lock.withLock {
            // In a real implementation, we'd track execution order
            // For now, return any snapshot
            _snapshots.values.first
        }
    }

    /// Create a child context for a nested execution.
    public func childContext(for stage: BuildStage) -> ExecutionContext {
        lock.withLock {
            ExecutionContext(
                stage: stage,
                graph: graph,
                platform: platform,
                reporter: reporter,
                baseEnvironment: Environment(_environment.variables),
                baseConfig: _imageConfig
            )
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
