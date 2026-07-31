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

import ArgumentParser
import ContainerAPIClient
import ContainerLog
import ContainerResource
import Logging

struct K8sList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List clusters and their nodes",
        aliases: ["ls"]
    )

    func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }

        let snapshots = try await ContainerClient().list(
            filters: ContainerListFilters(labels: [ResourceLabelKeys.plugin: K8sHelper.pluginName])
        )
        let rows = K8sHelper.buildK8sRows(from: snapshots)
        print(K8sHelper.renderTable(rows))
    }
}
