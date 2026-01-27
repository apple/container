//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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
    public var memoryUsageBytes: UInt64?
    /// Memory limit in bytes
    public var memoryLimitBytes: UInt64?
    /// CPU usage in microseconds
    public var cpuUsageUsec: UInt64?
    /// Network received bytes (sum of all interfaces)
    public var networkRxBytes: UInt64?
    /// Network transmitted bytes (sum of all interfaces)
    public var networkTxBytes: UInt64?
    /// Block I/O read bytes (sum of all devices)
    public var blockReadBytes: UInt64?
    /// Block I/O write bytes (sum of all devices)
    public var blockWriteBytes: UInt64?
    /// Number of processes in the container
    public var numProcesses: UInt64?

    public init(
        id: String,
        memoryUsageBytes: UInt64?,
        memoryLimitBytes: UInt64?,
        cpuUsageUsec: UInt64?,
        networkRxBytes: UInt64?,
        networkTxBytes: UInt64?,
        blockReadBytes: UInt64?,
        blockWriteBytes: UInt64?,
        numProcesses: UInt64?
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
    }
}
