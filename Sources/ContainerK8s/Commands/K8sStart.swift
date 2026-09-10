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
import Foundation
import Logging

public struct K8sStart: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a stopped Kubernetes cluster"
    )

    @Option(name: .long, help: "Cluster name (default: \(K8sHelper.defaultName))")
    var name: String = K8sHelper.defaultName

    public func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }
        let log = Logger(label: K8sHelper.pluginName)

        let client = ContainerClient()
        let container = try await client.get(id: name)

        guard container.configuration.labels[ResourceLabelKeys.plugin] == K8sHelper.pluginName else {
            log.error("container is not a k8s cluster, refusing start", metadata: ["name": "\(name)"])
            throw ContainerizationError(.invalidArgument, message: "\(name) is not a k8s cluster")
        }

        if container.status == .running {
            print(name)
            return
        }

        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }
        let process = try await client.bootstrap(id: name, stdio: io.stdio)
        try await process.start()
        try io.closeAfterStart()

        try await K8sHelper.waitForNodeBooted(containerId: name, client: client, log: log)
        try await K8sHelper.waitForReady(containerId: name, client: client, log: log)

        do {
            let fqdn = await K8sHelper.detectFQDN(name: name)
            let rawConfig = try await K8sHelper.fetchConfig(containerId: name, client: client, log: log)
            let config = try await K8sHelper.transformConfig(rawConfig, containerId: name, fqdn: fqdn, client: client)
            try K8sHelper.mergeConfig(config, containerId: name, log: log)
        } catch {
            log.warning("failed to write kubeconfig", metadata: ["name": "\(name)", "error": "\(error)"])
            log.info("cluster is running; use 'container k8s write-config --name \(name)' to write the kubeconfig")
        }

        print(name)
    }
}
