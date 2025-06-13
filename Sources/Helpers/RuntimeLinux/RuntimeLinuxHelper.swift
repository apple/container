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
import CVersion
import ContainerClient
import ContainerLog
import ContainerNetworkService
import ContainerSandboxService
import ContainerXPC
import Containerization
import ContainerizationError
import Foundation
import Logging

@main
struct RuntimeLinuxHelper: AsyncParsableCommand {
    static let label = "com.apple.container.runtime.container-runtime-linux"

    static let configuration = CommandConfiguration(
        commandName: "container-runtime-linux",
        abstract: "XPC Service for managing a Linux sandbox",
        version: releaseVersion()
    )

    @Flag(name: .long, help: "Enable debug logging")
    var debug = false

    @Option(name: .shortAndLong, help: "Sandbox UUID")
    var uuid: String

    @Option(name: .shortAndLong, help: "Root directory for the sandbox")
    var root: String

    var machServiceLabel: String {
        "\(Self.label).\(uuid)"
    }

    func run() async throws {
        let commandName = Self._commandName
        let log = setupLogger()
        log.info("starting \(commandName)")
        defer {
            log.info("stopping \(commandName)")
        }

        do {
            try adjustLimits()
            signal(SIGPIPE, SIG_IGN)

            log.info("configuring XPC server")
            let interfaceStrategy: any InterfaceStrategy
            #if !CURRENT_SDK
            if #available(macOS 26, *) {
                interfaceStrategy = NonisolatedInterfaceStrategy(log: log)
            } else {
                interfaceStrategy = IsolatedInterfaceStrategy()
            }
            #else
            interfaceStrategy = IsolatedInterfaceStrategy()
            #endif
            let server = SandboxService(root: .init(fileURLWithPath: root), interfaceStrategy: interfaceStrategy, log: log)
            let xpc = XPCServer(
                identifier: machServiceLabel,
                routes: [
                    SandboxRoutes.bootstrap.rawValue: server.bootstrap,
                    SandboxRoutes.createProcess.rawValue: server.createProcess,
                    SandboxRoutes.state.rawValue: server.state,
                    SandboxRoutes.stop.rawValue: server.stop,
                    SandboxRoutes.kill.rawValue: server.kill,
                    SandboxRoutes.resize.rawValue: server.resize,
                    SandboxRoutes.wait.rawValue: server.wait,
                    SandboxRoutes.start.rawValue: server.startProcess,
                    SandboxRoutes.dial.rawValue: server.dial,
                ],
                log: log
            )

            log.info("starting XPC server")
            try await xpc.listen()
        } catch {
            log.error("\(commandName) failed", metadata: ["error": "\(error)"])
            RuntimeLinuxHelper.exit(withError: error)
        }
    }

    private func setupLogger() -> Logger {
        LoggingSystem.bootstrap { label in
            OSLogHandler(
                label: label,
                category: "RuntimeLinuxHelper"
            )
        }
        var log = Logger(label: "com.apple.container")
        if debug {
            log.logLevel = .debug
        }
        log[metadataKey: "uuid"] = "\(uuid)"
        return log
    }

    private func adjustLimits() throws {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        limits.rlim_cur = 65536
        limits.rlim_max = 65536
        guard setrlimit(RLIMIT_NOFILE, &limits) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }

    private static func releaseVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? get_release_version().map { String(cString: $0) } ?? "0.0.0"
    }
}
