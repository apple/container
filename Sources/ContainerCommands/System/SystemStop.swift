//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import ContainerPlugin
import ContainerResource
import Containerization
import ContainerizationOS
import Foundation
import Logging

extension Application {
    public struct SystemStop: AsyncLoggableCommand {
        private static let stopTimeoutSeconds: Int32 = 5
        private static let shutdownTimeoutSeconds: Int32 = 20

        public static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop all `container` services"
        )

        @Option(name: .shortAndLong, help: "Launchd prefix for services")
        var prefix: String = "com.apple.container."

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let log = Logger(
                label: "com.apple.container.cli",
                factory: { label in
                    StreamLogHandler.standardOutput(label: label)
                }
            )

            let apiserverLabel = "\(prefix)apiserver"

            var running = true
            do {
                log.info("checking if APIServer is alive")
                _ = try await ClientHealthCheck.ping(timeout: .seconds(5))
            } catch {
                log.info("APIServer health check failed, skipping bootout")
                running = false
            }

            if running {
                let client = ContainerClient()
                log.info("stopping containers", metadata: ["stopTimeoutSeconds": "\(Self.stopTimeoutSeconds)"])
                do {
                    let containers = try await client.list().map { $0.id }
                    let opts = ContainerStopOptions(timeoutInSeconds: Self.stopTimeoutSeconds, signal: nil)
                    try await ContainerStop.stopContainers(
                        client: client,
                        containers: containers,
                        stopOptions: opts,
                    )
                } catch {
                    log.warning("failed to stop all containers", metadata: ["error": "\(error)"])
                }

                log.info("waiting for containers to exit")
                do {
                    for _ in 0..<Self.shutdownTimeoutSeconds {
                        let runningContainers = try await client.list(filters: ContainerListFilters(status: .running))
                        guard !runningContainers.isEmpty else {
                            break
                        }
                        try await Task.sleep(for: .seconds(1))
                    }
                } catch {
                    log.warning("failed to wait for all containers", metadata: ["error": "\(error)"])
                }
            }

            // Stopping the services is what this command is for, so it
            // happens whether or not the containers could be waited for, and
            // whether or not the API server answered its health check at all.
            // Asking the API server about its containers is asking the
            // service being stopped, and it is when that service is in a
            // bad way that stopping it matters most: leaving it running
            // because it could not answer leaves the one process that
            // needed stopping.
            log.info("stopping service", metadata: ["label": "\(apiserverLabel)"])
            do {
                if try !ServiceManager.deregisterAnyDomain(serviceLabel: apiserverLabel) {
                    log.warning(
                        "failed to stop service",
                        metadata: ["label": "\(apiserverLabel)", "error": "no launchd domain holds it"])
                }
            } catch {
                log.warning("failed to stop service", metadata: ["label": "\(apiserverLabel)", "error": "\(error)"])
            }

            // The domain a service was registered in is the one belonging to
            // the session that started it, which is not necessarily this one:
            // a system brought up from a terminal no window server owns sits
            // in `user/<uid>`, and this command run from a login session looks
            // in `gui/<uid>`. Either session can drive the other's services,
            // so a mismatch does not announce itself as a failure to reach
            // them; it announces itself as a stop that says it stopped
            // everything while every service it named is still running.
            try ServiceManager.enumerate()
                .filter { $0.hasPrefix(prefix) }
                .filter { $0 != apiserverLabel }
                .forEach {
                    log.info("stopping service", metadata: ["label": "\($0)"])
                    let stopped = (try? ServiceManager.deregisterAnyDomain(serviceLabel: $0)) ?? false
                    if !stopped {
                        log.warning("failed to stop service", metadata: ["label": "\($0)"])
                    }
                }
        }
    }
}
