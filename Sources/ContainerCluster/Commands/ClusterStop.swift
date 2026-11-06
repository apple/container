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
import ContainerResource
import ContainerizationError
import Logging

public struct ClusterStop: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a Kubernetes cluster and its nodes"
    )

    @Option(name: .long, help: "Cluster name")
    var name: String = ClusterHelper.defaultName

    @Option(name: .shortAndLong, help: "Signal to send to a node (default: the node image's stop signal)")
    var signal: String?

    @Option(name: .shortAndLong, help: "Seconds to wait before killing a node")
    var time: Int32 = ClusterHelper.nodeStopTimeoutSeconds

    public func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }
        let log = Logger(label: ClusterHelper.pluginName)

        let client = ContainerClient()
        let cluster = try await ClusterClient().get(name: name)
        let snapshots = try await client.list(
            filters: ContainerListFilters().withPlugin(ClusterHelper.pluginName))
        let running = ClusterHelper.nodesToStop(configuration: cluster.configuration, snapshots: snapshots)
        let options = ContainerStopOptions(timeoutInSeconds: time, signal: signal)

        var failures: [(name: String, error: Error)] = []

        let workers = running.filter { $0 != name }
        await withTaskGroup(of: (String, Error?).self) { group in
            for workerName in workers {
                group.addTask {
                    do {
                        try await client.stop(id: workerName, opts: options)
                        return (workerName, nil)
                    } catch {
                        return (workerName, error)
                    }
                }
            }
            for await (workerName, error) in group {
                if let error {
                    log.error("failed to stop worker container", metadata: ["name": "\(workerName)", "error": "\(error)"])
                    failures.append((workerName, error))
                }
            }
        }

        if running.contains(name) {
            do {
                try await client.stop(id: name, opts: options)
            } catch {
                log.error("failed to stop cluster container", metadata: ["name": "\(name)", "error": "\(error)"])
                failures.append((name, error))
            }
        }

        guard failures.isEmpty else {
            let details = failures.map { "\($0.name): \($0.error)" }.joined(separator: "; ")
            throw ContainerizationError(.internalError, message: "failed to stop node(s): \(details)")
        }

        print(name)
    }
}
