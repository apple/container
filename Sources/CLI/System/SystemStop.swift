//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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
import ContainerClient
import ContainerPlugin
import ContainerizationOS
import Foundation
import Logging

extension Application {
    struct SystemStop: AsyncParsableCommand {
        private static let stopTimeoutSeconds: Int32 = 5
        private static let shutdownTimeoutSeconds: Int32 = 20

        static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop all `container` services"
        )

        @Option(name: .shortAndLong, help: "Launchd prefix for `container` services")
        var prefix: String = "com.apple.container."

        func run() async throws {
            let log = Logger(
                label: "com.apple.container.cli",
                factory: { label in
                    StreamLogHandler.standardOutput(label: label)
                }
            )

            let launchdDomainString = try ServiceManager.getDomainString()
            let fullLabel = "\(launchdDomainString)/\(prefix)apiserver"

            log.info("stopping containers", metadata: ["stopTimeoutSeconds": "\(Self.stopTimeoutSeconds)"])
            do {
                let containers = try await ClientContainer.list()
                let signal = try Signals.parseSignal("SIGTERM")
                let opts = ContainerStopOptions(timeoutInSeconds: Self.stopTimeoutSeconds, signal: signal)
                let failed = try await ContainerStop.stopContainers(containers: containers, stopOptions: opts)
                if !failed.isEmpty {
                    log.warning("some containers could not be stopped gracefully", metadata: ["ids": "\(failed)"])
                }

            } catch {
                log.warning("failed to stop all containers", metadata: ["error": "\(error)"])
            }

            log.info("waiting for containers to exit")
            do {
                for _ in 0..<Self.shutdownTimeoutSeconds {
                    let anyRunning = try await ClientContainer.list()
                        .contains { $0.status == .running }
                    guard anyRunning else {
                        break
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            } catch {
                log.warning("failed to wait for all containers", metadata: ["error": "\(error)"])
            }

            log.info("stopping service", metadata: ["label": "\(fullLabel)"])
            try ServiceManager.deregister(fullServiceLabel: fullLabel)
            // Note: The assumption here is that we would have registered the launchd services
            // in the same domain as `launchdDomainString`. This is a fairly sane assumption since
            // if somehow the launchd domain changed, XPC interactions would not be possible.
            try ServiceManager.enumerate()
                .filter { $0.hasPrefix(prefix) }
                .filter { $0 != fullLabel }
                .map { "\(launchdDomainString)/\($0)" }
                .forEach {
                    log.info("stopping service", metadata: ["label": "\($0)"])
                    try? ServiceManager.deregister(fullServiceLabel: $0)
                }
        }
    }
}
