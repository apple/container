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

import ContainerPlugin
import ContainerizationExtras
import Foundation
import Logging

/// Runs a runtime plugin's `cleanup --root <bundle> --uuid <id>` subcommand, which releases
/// resources the plugin keeps outside the bundle
enum RuntimeCleanupHook {
    static let defaultTimeout: Duration = .seconds(60)

    /// Returns whether the plugin exited 0. Failures are logged, not thrown: a broken plugin must not block delete.
    /// - timeout: time bound for delete operation, will result in killing the plugin if it takes too long
    @discardableResult
    static func run(
        plugin: Plugin,
        root: URL,
        id: String,
        log: Logger,
        timeout: Duration = defaultTimeout
    ) async -> Bool {
        let metadata: Logger.Metadata = ["id": "\(id)", "plugin": "\(plugin.binaryURL)"]

        let (exits, exit) = AsyncStream<Int32>.makeStream()
        let process = Process()
        process.executableURL = plugin.binaryURL
        process.arguments = [
            RuntimeCleanupCommand.name,
            "--\(RuntimeCleanupCommand.rootOption)", root.path,
            "--\(RuntimeCleanupCommand.uuidOption)", id,
        ]
        process.terminationHandler = {
            exit.yield($0.terminationStatus)
            exit.finish()
        }

        do {
            try process.run()
        } catch {
            log.warning("failed to launch runtime cleanup hook", metadata: metadata.merging(["error": "\(error)"]) { $1 })
            return false
        }

        let status: Int32
        do {
            status = try await Timeout.run(for: timeout) {
                for await status in exits {
                    return status
                }
                throw CancellationError()
            }
        } catch {
            log.warning("runtime cleanup hook timed out; sending SIGKILL", metadata: metadata.merging(["timeout": "\(timeout)"]) { $1 })
            // Terminate the runtime plugin along with any spawned children
            kill(-process.processIdentifier, SIGKILL)
            return false
        }

        guard status == 0 else {
            log.error("runtime cleanup hook failed or is not implemented", metadata: metadata.merging(["terminationStatus": "\(status)"]) { $1 })
            return false
        }
        return true
    }
}
