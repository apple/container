//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

/// Statistics for a container suitable for CLI display.
public struct ContainerStats: Sendable, Codable {
    /// Container ID
    public var id: String
    /// Physical memory usage in bytes
    public var memoryUsageBytes: UInt64
    /// Memory limit in bytes
    public var memoryLimitBytes: UInt64
    /// CPU usage in microseconds
    public var cpuUsageUsec: UInt64
    /// Network received bytes (sum of all interfaces)
    public var networkRxBytes: UInt64
    /// Network transmitted bytes (sum of all interfaces)
    public var networkTxBytes: UInt64
    /// Block I/O read bytes (sum of all devices)
    public var blockReadBytes: UInt64
    /// Block I/O write bytes (sum of all devices)
    public var blockWriteBytes: UInt64
    /// Number of processes in the container
    public var numProcesses: UInt64

    // Extended I/O metrics
    /// Read operations per second
    public var readOpsPerSec: Double?
    /// Write operations per second
    public var writeOpsPerSec: Double?
    /// Average read latency in milliseconds
    public var readLatencyMs: Double?
    /// Average write latency in milliseconds
    public var writeLatencyMs: Double?
    /// Average fsync latency in milliseconds
    public var fsyncLatencyMs: Double?
    /// I/O queue depth
    public var queueDepth: UInt64?
    /// Percentage of dirty pages
    public var dirtyPagesPercent: Double?
    /// Storage backend type (e.g., "apfs", "ext4", "virtio")
    public var storageBackend: String?

    public init(
        id: String,
        memoryUsageBytes: UInt64,
        memoryLimitBytes: UInt64,
        cpuUsageUsec: UInt64,
        networkRxBytes: UInt64,
        networkTxBytes: UInt64,
        blockReadBytes: UInt64,
        blockWriteBytes: UInt64,
        numProcesses: UInt64,
        readOpsPerSec: Double? = nil,
        writeOpsPerSec: Double? = nil,
        readLatencyMs: Double? = nil,
        writeLatencyMs: Double? = nil,
        fsyncLatencyMs: Double? = nil,
        queueDepth: UInt64? = nil,
        dirtyPagesPercent: Double? = nil,
        storageBackend: String? = nil
    ) {
        self.id = id
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.cpuUsageUsec = cpuUsageUsec
        self.networkRxBytes = networkRxBytes
        self.networkTxBytes = networkTxBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.numProcesses = numProcesses
        self.readOpsPerSec = readOpsPerSec
        self.writeOpsPerSec = writeOpsPerSec
        self.readLatencyMs = readLatencyMs
        self.writeLatencyMs = writeLatencyMs
        self.fsyncLatencyMs = fsyncLatencyMs
        self.queueDepth = queueDepth
        self.dirtyPagesPercent = dirtyPagesPercent
        self.storageBackend = storageBackend
    }
}
