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
import ContainerLog
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import SystemPackage

struct K8sLoadImage: AsyncParsableCommand {
    private static let ctrPath = "/usr/local/bin/ctr"

    static let configuration = CommandConfiguration(
        commandName: "load-image",
        abstract: "Load a container image into a cluster's containerd"
    )

    @Option(name: .long, help: "Cluster name (default: \(K8sHelper.defaultName))")
    var name: String = K8sHelper.defaultName

    @Argument(help: "Image reference to load (e.g. demo-api:latest)")
    var image: String

    @Option(
        help: "Platform of the image to load (format: os/arch[/variant], default: linux/arm64)"
    )
    var platform: String?

    func run() async throws {
        LoggingSystem.bootstrap { _ in StderrLogHandler() }
        let log = Logger(label: K8sHelper.pluginName)

        let tmpFile = FilePath(FileManager.default.temporaryDirectory.path(percentEncoded: false))
            .appending("k8s-image-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(atPath: tmpFile.string) }

        let containerSystemConfig: ContainerSystemConfig = try await ConfigurationLoader.load()

        let client = ContainerClient()

        // Guard: refuse to operate on a container not owned by this plugin.
        let container = try await client.get(id: name)
        guard container.configuration.labels[ResourceLabelKeys.plugin] == K8sHelper.pluginName else {
            log.error("container is not a k8s cluster, refusing image load", metadata: ["name": "\(name)"])
            throw ContainerizationError(.invalidArgument, message: "\(name) is not a k8s cluster")
        }

        log.info("Saving image", metadata: ["ref": "\(image)"])
        let fq = K8sHelper.fqReference(image)
        let resolvedPlatform = try platform.map { try Platform(from: $0) } ?? Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")
        try await ClientImage.save(references: [fq], out: tmpFile.string, platform: resolvedPlatform, containerSystemConfig: containerSystemConfig)

        log.info("Importing image into cluster", metadata: ["target": "\(name)"])
        guard let inputHandle = FileHandle(forReadingAtPath: tmpFile.string) else {
            throw ContainerizationError(.internalError, message: "failed to open image tar: \(tmpFile)")
        }
        defer { try? inputHandle.close() }

        let importConfig = ProcessConfiguration(
            executable: Self.ctrPath,
            arguments: ["--namespace", "k8s.io", "images", "import", "-"],
            environment: [],
            terminal: false
        )
        let importProc = try await client.createProcess(
            containerId: name,
            processId: UUID().uuidString.lowercased(),
            configuration: importConfig,
            stdio: [inputHandle, nil, nil]
        )
        try await importProc.start()
        let importCode = try await importProc.wait()
        guard importCode == 0 else {
            throw ContainerizationError(
                .internalError,
                message: "ctr import exited \(importCode) on \(name)")
        }

        // Tag with the fully-qualified docker.io/library/ name that kubelet expects,
        // but only for short (unqualified) references.
        if fq != image {
            log.info("Tagging image for kubelet", metadata: ["short": "\(image)", "fq": "\(fq)"])
            let tagConfig = ProcessConfiguration(
                executable: Self.ctrPath,
                arguments: ["--namespace", "k8s.io", "images", "tag", fq, image],
                environment: [],
                terminal: false
            )
            let tagProc = try await client.createProcess(
                containerId: name,
                processId: UUID().uuidString.lowercased(),
                configuration: tagConfig,
                stdio: [nil, nil, nil]
            )
            try await tagProc.start()
            let tagCode = try await tagProc.wait()
            guard tagCode == 0 else {
                throw ContainerizationError(
                    .internalError,
                    message: "ctr tag exited \(tagCode) on \(name)")
            }
        }
    }
}
