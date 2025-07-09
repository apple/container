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
import ContainerizationError
import Foundation
import Logging

extension Application {
    struct SystemStatus: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show the status of `container` services"
        )

        @Option(name: .shortAndLong, help: "Launchd prefix for `container` services")
        var prefix: String = "com.apple.container."

        func run() async throws {
            let isRegistered = try ServiceManager.isRegistered(fullServiceLabel: "\(prefix)apiserver")
            if !isRegistered {
                print("apiserver is not running and not registered with launchd")
                Application.exit(withError: ExitCode(1))
            }

            // Now ping our friendly daemon. Fail after 10 seconds with no response.
            do {
                print("Verifying apiserver is running...")
                try await ClientHealthCheck.ping(timeout: .seconds(10))
                print("apiserver is running")
            } catch {
                print("apiserver is not running")
                Application.exit(withError: ExitCode(1))
            }
        }
    }
}
