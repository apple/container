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
import ContainerizationError
import Foundation
import Logging

extension Application {

    struct SystemRestart: AsyncParsableCommand {
        private static let stopTimeoutSeconds: Int32 = 5

        static let configuration = CommandConfiguration(
            commandName: "restart",
            abstract: "Restart API server for `container`"
        )

        @Option(name: .shortAndLong, help: "Launchd prefix for `container` services")
        var prefix: String = "com.apple.container."

        func run() async throws {
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
            
            let launchdDomainString = try ServiceManager.getDomainString()
            let fullLabel = "\(launchdDomainString)/\(prefix)apiserver"
            try ServiceManager.kickstart(fullServiceLabel: fullLabel)
            // Now ping our friendly daemon. Fail after 10 seconds with no response.
            do {
                print("Verifying apiserver is running...")
                try await ClientHealthCheck.ping(timeout: .seconds(10))
                print("Done")
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to get a response from apiserver after 10 seconds: \(error)"
                )
            }
        }
    }
}
