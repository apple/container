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
import TerminalProgress

extension Application {
    struct SystemStart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start `container` services"
        )

        @Option(name: .shortAndLong, help: "Path to the `container-apiserver` binary")
        var path: String = Bundle.main.executablePath ?? ""

        @Flag(name: .long, help: "Enable debug logging for the runtime daemon.")
        var debug = false

        @Flag(name: .long, help: "Do not prompt for confirmation before installing runtime dependencies")
        var installDependencies: Bool = false

        func run() async throws {
            // Without the true path to the binary in the plist, `container-apiserver` won't launch properly.
            let executableUrl = URL(filePath: path)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent("container-apiserver")

            var args = [executableUrl.absolutePath()]
            if debug {
                args.append("--debug")
            }

            let apiServerDataUrl = appRoot.appending(path: "apiserver")
            try! FileManager.default.createDirectory(at: apiServerDataUrl, withIntermediateDirectories: true)
            let env = ProcessInfo.processInfo.environment.filter { key, _ in
                key.hasPrefix("CONTAINER_")
            }

            let logURL = apiServerDataUrl.appending(path: "apiserver.log")
            let plist = LaunchPlist(
                label: "com.apple.container.apiserver",
                arguments: args,
                environment: env,
                limitLoadToSessionType: [.Aqua, .Background, .System],
                runAtLoad: true,
                stdout: logURL.path,
                stderr: logURL.path,
                machServices: ["com.apple.container.apiserver"]
            )

            let plistURL = apiServerDataUrl.appending(path: "apiserver.plist")
            let data = try plist.encode()
            try data.write(to: plistURL)

            try ServiceManager.register(plistPath: plistURL.path)

            // Now ping our friendly daemon. Fail if we don't get a response.
            do {
                print("Verifying apiserver is running...")
                try await ClientHealthCheck.ping(timeout: .seconds(10))
                print("Done")
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to get a response from apiserver: \(error)"
                )
            }

            var kernelConfigured: Bool = false
            var missingDependencies: [Dependencies] = []
            if await !initImageExists() {
                missingDependencies.append(.initFs)
            }
            if await !kernelExists() {
                kernelConfigured = true
                missingDependencies.append(.kernel)
            }
            guard missingDependencies.count > 0 else {
                return
            }

            print("Missing required runtime dependencies:")
            for (idx, dependency) in missingDependencies.enumerated() {
                print(" \(idx+1). \(dependency.rawValue)")
            }

            if !installDependencies {
                print("Would like to install them now? [Y/n]: ", terminator: "")
                guard let read = readLine(strippingNewline: true) else {
                    throw ContainerizationError(.internalError, message: "Failed to read user input")
                }
                guard read.lowercased() == "y" || read.count == 0 else {
                    if !kernelConfigured {
                        print("Please use the `container system kernel set` command to configure the kernel")
                    }
                    return
                }
            }
            try await installDeps(deps: missingDependencies)
        }

        private func installDeps(deps: [Dependencies]) async throws {
            if deps.contains(.kernel) {
                try await installDefaultKernel()
            }
            if deps.contains(.initFs) {
                try await installInitialFilesystem()
            }
        }

        private func installInitialFilesystem() async throws {
            let reference = ClientDefaults.get(key: .defaultInitImage)
            let pullCommand = ImagePull(reference: reference)
            print("Installing initial filesystem from [\(reference)]...")
            try await pullCommand.run()
        }

        private func installDefaultKernel() async throws {
            let defaultKernelURL = ClientDefaults.get(key: .defaultKernelURL)
            let defaultKernelBinaryPath = ClientDefaults.get(key: .defaultKernelBinaryPath)
            print("Installing default kernel from [\(defaultKernelURL)]...")
            try await KernelSet.downloadAndInstallWithProgressBar(tarRemoteURL: defaultKernelURL, kernelFilePath: defaultKernelBinaryPath)
        }

        private func initImageExists() async -> Bool {
            do {
                let img = try await ClientImage.get(reference: ClientDefaults.get(key: .defaultInitImage))
                let _ = try await img.getSnapshot(platform: .current)
                return true
            } catch {
                return false
            }
        }

        private func kernelExists() async -> Bool {
            do {
                try await ClientKernel.getDefaultKernel(for: .current)
                return true
            } catch {
                return false
            }
        }
    }

    private enum Dependencies: String {
        case kernel = "Kernel"
        case initFs = "Initial filesystem"
    }
}
