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
import ContainerResource
import ContainerizationError
import ContainerizationOS
import Foundation
import Logging

extension K8sHelper {
    // MARK: - Readiness

    public static func runProbe(client: ContainerClient, containerId: String, arguments: [String]) async throws -> Int32 {
        let devNull = FileHandle(forWritingAtPath: "/dev/null")
        defer { try? devNull?.close() }
        let probe = ProcessConfiguration(
            executable: kubectlPath,
            arguments: arguments,
            environment: [kubeconfigEnv],
            terminal: false)
        let proc = try await client.createProcess(
            containerId: containerId,
            processId: UUID().uuidString.lowercased(),
            configuration: probe,
            stdio: [nil, devNull, devNull])
        try await proc.start()
        return try await proc.wait()
    }

    public static func waitForNodeBooted(containerId: String, client: ContainerClient, log: Logger) async throws {
        let timeout = 120
        log.info("Waiting for node to boot", metadata: ["node": "\(containerId)"])
        for attempt in 1...timeout {
            let result = try await execCapture(
                containerId: containerId, executable: "/bin/sh",
                arguments: ["-c", "test -S /run/containerd/containerd.sock"], client: client)
            if result.code == 0 { return }
            if attempt == timeout {
                log.info("check container logs with 'container logs \(containerId)'")
                throw ContainerizationError(
                    .timeout,
                    message: "node \(containerId) did not boot within \(timeout * 2)s: containerd socket not present at /run/containerd/containerd.sock"
                )
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    static func waitForReady(containerId: String, client: ContainerClient, log: Logger) async throws {
        let nodeReadyTimeout = 180
        let podReadyTimeout = 300

        log.info("Waiting for control-plane node to become ready")
        for attempt in 1...nodeReadyTimeout {
            let code: Int32
            do {
                code = try await runProbe(
                    client: client, containerId: containerId,
                    arguments: ["wait", "--for=condition=Ready", "node", "--all", "--timeout=2s"])
            } catch {
                throw ContainerizationError(
                    .internalError, message: "k8s cluster \(containerId) stopped unexpectedly during startup: \(error)")
            }
            if code == 0 { break }
            if attempt == nodeReadyTimeout {
                log.info("inspect node state with 'container exec \(containerId) kubectl get nodes -o wide'")
                throw ContainerizationError(
                    .timeout,
                    message: "k8s cluster \(containerId) control-plane node did not become Ready within \(nodeReadyTimeout * 2)s"
                )
            }
            try await Task.sleep(for: .seconds(2))
        }

        log.info("Waiting for kube-system pods to become ready")
        for attempt in 1...podReadyTimeout {
            let code: Int32
            do {
                code = try await runProbe(
                    client: client, containerId: containerId,
                    arguments: ["wait", "--for=condition=Available", "deployment/coredns", "-n", "kube-system", "--timeout=2s"])
            } catch {
                throw ContainerizationError(
                    .internalError, message: "k8s cluster \(containerId) stopped unexpectedly during startup: \(error)")
            }
            if code == 0 { return }
            if attempt < podReadyTimeout {
                try await Task.sleep(for: .seconds(2))
            }
        }
        log.info("inspect pod state with 'container exec \(containerId) kubectl get pods -n kube-system'")
        throw ContainerizationError(
            .timeout,
            message: "k8s cluster \(containerId) kube-system pods did not become available within \(podReadyTimeout * 2)s"
        )
    }
}
