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
import ContainerizationError
import Logging

struct K8sDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a Kubernetes cluster",
        aliases: ["rm"]
    )

    @Option(name: .long, help: "Cluster name (default: \(K8sHelper.defaultName))")
    var name: String = K8sHelper.defaultName

    func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }
        let log = Logger(label: K8sHelper.pluginName)

        let client = ContainerClient()

        if let container = try? await client.get(id: name) {
            guard container.configuration.labels[ResourceLabelKeys.plugin] == K8sHelper.pluginName else {
                log.error("container is not a k8s cluster, refusing delete", metadata: ["name": "\(name)"])
                throw ContainerizationError(.invalidArgument, message: "\(name) is not a k8s cluster")
            }
        }

        do {
            try? await client.stop(id: name)
            try await client.delete(id: name)
        } catch let error as ContainerizationError where error.code == .notFound {
            log.debug("cluster container not found, skipping delete", metadata: ["name": "\(name)"])
        }

        try K8sHelper.removeConfig(containerId: name, log: log)
        print(name)
    }
}
