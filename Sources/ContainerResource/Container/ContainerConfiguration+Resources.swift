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

import ContainerizationError
import ContainerizationExtras
import Foundation

extension ContainerConfiguration.Resources {
    /// The smallest memory allocation a container may be created with.
    ///
    /// This protects against a memory amount that would leave the guest unable to boot. It can go lower,
    /// but this is a somewhat safe threshold. Containerization also gives a little extra than the user
    /// asked for to account for guest agent overhead.
    public static let minimumMemoryInBytes: UInt64 = 200.mib()

    /// The most CPUs a container may be created with: the number of CPU cores on the host.
    public static var maximumCPUs: Int { ProcessInfo.processInfo.processorCount }

    /// Checks that a requested CPU count is at least 1 and no more than the host's core count.
    ///
    /// - Throws: `.invalidArgument` if `cpus` is out of range.
    public static func validate(cpus: Int64) throws {
        guard cpus >= 1, cpus <= Int64(maximumCPUs) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "cpus must be between 1 and \(maximumCPUs), the number of CPU cores on this host (got \(cpus))")
        }
    }

    /// Checks that a requested memory amount meets `minimumMemoryInBytes`.
    ///
    /// - Throws: `.invalidArgument` if `bytes` is too small.
    public static func validate(memoryInBytes bytes: UInt64) throws {
        guard bytes >= minimumMemoryInBytes else {
            throw ContainerizationError(
                .invalidArgument,
                message: "minimum memory amount allowed is \(minimumMemoryInBytes / 1.mib()) MiB (got \(bytes) bytes)")
        }
    }
}
