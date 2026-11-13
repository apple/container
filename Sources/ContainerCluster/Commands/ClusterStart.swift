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
import ContainerClusterServiceClient
import ContainerLog
import ContainerPersistence
import ContainerizationError
import Darwin
import Foundation
import Logging
import TerminalProgress

public struct ClusterStart: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a stopped Kubernetes cluster and its nodes"
    )

    @Option(name: .long, help: "Cluster name")
    var name: String = ClusterHelper.defaultName

    public func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }
        let log = Logger(label: ClusterHelper.pluginName)

        let cluster = try await ClusterClient().get(name: name)
        if cluster.status.state == .running {
            print(name)
            return
        }

        let configuration = cluster.configuration
        let containerSystemConfig: ContainerSystemConfig = try await ClientHealthCheck.loadContainerSystemConfig()

        let isTTY = isatty(FileHandle.standardError.fileDescriptor) == 1
        // TotalTasks include:
        // control plane, one per worker, wait, write kubeconfig.
        let progressConfig = try ProgressConfig(
            showSpinner: isTTY,
            showTasks: true,
            showItems: true,
            ignoreSmallSize: true,
            totalTasks: configuration.nodes.count + 2,
            clearOnFinish: isTTY,
            outputMode: isTTY ? .ansi : .plain
        )

        let progress = ProgressBar(config: progressConfig)
        defer { progress.finish() }
        progress.start()

        let clusterBootstrapper = try ClusterBootstrapper(configuration: configuration, containerSystemConfig: containerSystemConfig)

        try await clusterBootstrapper.start(configuration: configuration, progress: { progress.set(description: $0) }, log: log)

        progress.finish()
        print(name)
    }
}
