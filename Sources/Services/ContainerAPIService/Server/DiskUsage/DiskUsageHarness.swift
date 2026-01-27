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

import ContainerAPIClient
import ContainerXPC
import ContainerizationError
import Foundation
import Logging

/// XPC harness for disk usage operations
public struct DiskUsageHarness: Sendable {
    let log: Logger
    let service: DiskUsageService

    public init(service: DiskUsageService, log: Logger) {
        self.log = log
        self.service = service
    }

    @Sendable
    public func get(_ message: XPCMessage) async throws -> XPCMessage {
        do {
            let stats = try await service.calculateDiskUsage()
            let data = try JSONEncoder().encode(stats)

            let reply = message.reply()
            reply.set(key: .diskUsageStats, value: data)
            return reply
        } catch {
            log.error("failed to get disk usage", metadata: ["error": "\(error)"])
            throw ContainerizationError(
                .internalError,
                message: "failed to get disk usage",
                cause: error
            )
        }
    }
}
