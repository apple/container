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

import ContainerXPC
import ContainerizationError
import Foundation

/// Client API for disk usage operations
public struct ClientDiskUsage {
    static let serviceIdentifier = "com.apple.container.apiserver"

    /// Get disk usage statistics for all resource types
    public static func get() async throws -> DiskUsageStats {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .systemDiskUsage)
        let reply = try await client.send(message)

        guard let responseData = reply.dataNoCopy(key: .diskUsageStats) else {
            throw ContainerizationError(
                .internalError,
                message: "invalid response from server: missing disk usage data"
            )
        }

        return try JSONDecoder().decode(DiskUsageStats.self, from: responseData)
    }
}
