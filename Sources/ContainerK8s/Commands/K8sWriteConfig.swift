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
import Foundation
import Logging
import SystemPackage

public struct K8sWriteConfig: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "write-config",
        abstract: "Write the cluster context to a Kubernetes configuration file"
    )

    @Option(name: .long, help: "Cluster name (default: \(K8sHelper.defaultName))")
    var name: String = K8sHelper.defaultName

    @Option(name: .long, help: "Path to the kubeconfig file to write or append to (default: ~/.kube/config)")
    var kubeconfig: String?

    public func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }
        let log = Logger(label: K8sHelper.pluginName)

        let targetPath = kubeconfig.map { FilePath($0) }
        let client = ContainerClient()
        let fqdn = await K8sHelper.detectFQDN(name: name)
        let rawConfig = try await K8sHelper.fetchConfig(containerId: name, client: client, log: log)
        let config = try await K8sHelper.transformConfig(rawConfig, containerId: name, fqdn: fqdn, client: client)
        try K8sHelper.mergeConfig(config, containerId: name, targetPath: targetPath, log: log)
    }
}
