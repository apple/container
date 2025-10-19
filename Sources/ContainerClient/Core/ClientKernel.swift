//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import TerminalProgress

public struct ClientKernel {
    static let serviceIdentifier = "com.apple.container.apiserver"
}

extension ClientKernel {
    private static func newClient() -> XPCClient {
        XPCClient(service: serviceIdentifier)
    }

    public static func installKernel(kernelFilePath: String, platform: SystemPlatform, force: Bool) async throws {
        let client = newClient()
        let message = XPCMessage(route: .installKernel)

        message.set(key: .kernelFilePath, value: kernelFilePath)
        message.set(key: .kernelForce, value: force)

        let platformData = try JSONEncoder().encode(platform)
        message.set(key: .systemPlatform, value: platformData)
        try await client.send(message)
    }

    public static func installKernelFromTar(tarFile: String, kernelFilePath: String, platform: SystemPlatform, progressUpdate: ProgressUpdateHandler? = nil, force: Bool)
        async throws
    {
        let client = newClient()
        let message = XPCMessage(route: .installKernel)

        message.set(key: .kernelTarURL, value: tarFile)
        message.set(key: .kernelFilePath, value: kernelFilePath)
        message.set(key: .kernelForce, value: force)

        let platformData = try JSONEncoder().encode(platform)
        message.set(key: .systemPlatform, value: platformData)

        var progressUpdateClient: ProgressUpdateClient?
        if let progressUpdate {
            progressUpdateClient = await ProgressUpdateClient(for: progressUpdate, request: message)
        }

        try await client.send(message)
        await progressUpdateClient?.finish()
    }

    @discardableResult
    public static func getDefaultKernel(for platform: SystemPlatform) async throws -> Kernel {
        let client = newClient()
        let message = XPCMessage(route: .getDefaultKernel)

        let platformData = try JSONEncoder().encode(platform)
        message.set(key: .systemPlatform, value: platformData)
        do {
            let reply = try await client.send(message)
            guard let kData = reply.dataNoCopy(key: .kernel) else {
                throw ContainerizationError(.internalError, message: "Missing kernel data from XPC response")
            }

            let kernel = try JSONDecoder().decode(Kernel.self, from: kData)
            return kernel
        } catch let err as ContainerizationError {
            guard err.isCode(.notFound) else {
                throw err
            }
            throw ContainerizationError(
                .notFound, message: "Default kernel not configured for architecture \(platform.architecture). Please use the `container system kernel set` command to configure it")
        }
    }
}

extension SystemPlatform {
    public static var current: SystemPlatform {
        switch Platform.current.architecture {
        case "arm64":
            return .linuxArm
        case "amd64":
            return .linuxAmd
        default:
            fatalError("Unknown architecture")
        }
    }
}
