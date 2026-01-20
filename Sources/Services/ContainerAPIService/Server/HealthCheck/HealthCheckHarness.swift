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

import CVersion
import ContainerAPIClient
import ContainerVersion
import ContainerXPC
import Containerization
import Foundation
import Logging

public actor HealthCheckHarness {
    private let appRoot: URL
    private let installRoot: URL
    private let log: Logger

    public init(appRoot: URL, installRoot: URL, log: Logger) {
        self.appRoot = appRoot
        self.installRoot = installRoot
        self.log = log
    }

    @Sendable
    public func ping(_ message: XPCMessage) async -> XPCMessage {
        let reply = message.reply()
        reply.set(key: .appRoot, value: appRoot.absoluteString)
        reply.set(key: .installRoot, value: installRoot.absoluteString)
        reply.set(key: .apiServerVersion, value: ReleaseVersion.singleLine(appName: "container-apiserver"))
        reply.set(key: .apiServerCommit, value: get_git_commit().map { String(cString: $0) } ?? "unspecified")
        // Extra optional fields for richer client display
        reply.set(key: .apiServerBuild, value: ReleaseVersion.buildType())
        reply.set(key: .apiServerAppName, value: "container API Server")
        return reply
    }
}
