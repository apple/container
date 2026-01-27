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

public enum ClientHealthCheck {
    static let serviceIdentifier = "com.apple.container.apiserver"
}

extension ClientHealthCheck {
    private static func newClient() -> XPCClient {
        XPCClient(service: serviceIdentifier)
    }

    public static func ping(timeout: Duration? = .seconds(5)) async throws -> SystemHealth {
        let client = Self.newClient()
        let request = XPCMessage(route: .ping)
        let reply = try await client.send(request, responseTimeout: timeout)
        guard let appRootValue = reply.string(key: .appRoot), let appRoot = URL(string: appRootValue) else {
            throw ContainerizationError(.internalError, message: "failed to decode appRoot in health check")
        }
        guard let installRootValue = reply.string(key: .installRoot), let installRoot = URL(string: installRootValue) else {
            throw ContainerizationError(.internalError, message: "failed to decode installRoot in health check")
        }
        guard let apiServerVersion = reply.string(key: .apiServerVersion) else {
            throw ContainerizationError(.internalError, message: "failed to decode apiServerVersion in health check")
        }
        guard let apiServerCommit = reply.string(key: .apiServerCommit) else {
            throw ContainerizationError(.internalError, message: "failed to decode apiServerCommit in health check")
        }
        guard let apiServerBuild = reply.string(key: .apiServerBuild) else {
            throw ContainerizationError(.internalError, message: "failed to decode apiServerBuild in health check")
        }
        guard let apiServerAppName = reply.string(key: .apiServerAppName) else {
            throw ContainerizationError(.internalError, message: "failed to decode apiServerAppName in health check")
        }
        return .init(
            appRoot: appRoot,
            installRoot: installRoot,
            apiServerVersion: apiServerVersion,
            apiServerCommit: apiServerCommit,
            apiServerBuild: apiServerBuild,
            apiServerAppName: apiServerAppName
        )
    }
}
