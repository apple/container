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
import ContainerPersistence
import ContainerPlugin
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import SwiftProtobuf

extension Application {
    public struct ImageList: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List images",
            aliases: ["ls"])

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: .shortAndLong, help: "Only output the image name")
        var quiet = false

        @Flag(name: .shortAndLong, help: "Verbose output")
        var verbose = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public mutating func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try SystemRuntimeOptions.loadConfig(
                configFile: SystemRuntimeOptions.configFileFromAppRoot(ApplicationRoot.url)
            )
            try Self.validate(format: format, quiet: quiet, verbose: verbose)

            var images = try await ClientImage.list().filter { img in
                !Utility.isInfraImage(name: img.reference, builderImage: containerSystemConfig.build.image, initImage: containerSystemConfig.vminit.image)
            }
            images.sort { $0.reference < $1.reference }

            if format == .json {
                try await Self.emitJSON(images: images)
                return
            }

            if quiet {
                for image in images {
                    let processedReferenceString = try ClientImage.denormalizeReference(image.reference, containerSystemConfig: containerSystemConfig)
                    print(processedReferenceString)
                }
                return
            }

            if verbose {
                let items = try await Self.buildVerboseItems(images: images, containerSystemConfig: containerSystemConfig)
                Output.emit(Output.renderTable(items))
                return
            }

            let items = try await Self.buildTableItems(images: images, containerSystemConfig: containerSystemConfig)
            Output.emit(Output.renderTable(items))
        }

        private static func validate(format: ListFormat, quiet: Bool, verbose: Bool) throws {
            if quiet && verbose {
                throw ContainerizationError(.invalidArgument, message: "cannot use flag --quiet and --verbose together")
            }
            let modifier = quiet || verbose
            if modifier && format == .json {
                throw ContainerizationError(.invalidArgument, message: "cannot use flag --quiet or --verbose along with --format json")
            }
        }

        private static func emitJSON(images: [ClientImage]) async throws {
            let formatter = ByteCountFormatter()
            var printableImages: [PrintableImage] = []
            for image in images {
                let size = try await ClientImage.getFullImageSize(image: image)
                let formattedSize = formatter.string(fromByteCount: size)
                printableImages.append(
                    PrintableImage(reference: image.reference, fullSize: formattedSize, descriptor: image.descriptor)
                )
            }
            try Output.emit(Output.renderJSON(printableImages))
        }

        private static func buildTableItems(images: [ClientImage], containerSystemConfig: ContainerSystemConfig) async throws -> [ImageRow] {
            var items: [ImageRow] = []
            for image in images {
                let processedReferenceString = try ClientImage.denormalizeReference(image.reference, containerSystemConfig: containerSystemConfig)
                let reference = try ContainerizationOCI.Reference.parse(processedReferenceString)
                let digest = try await image.resolved().digest
                items.append(
                    ImageRow(
                        name: reference.name,
                        tag: reference.tag ?? "<none>",
                        trimmedDigest: Utility.trimDigest(digest: digest)
                    ))
            }
            return items
        }

        private static func buildVerboseItems(images: [ClientImage], containerSystemConfig: ContainerSystemConfig) async throws -> [VerboseImageRow] {
            let formatter = ByteCountFormatter()
            var items: [VerboseImageRow] = []
            for image in images {
                let imageDigest = try await image.resolved().digest
                let processedReferenceString = try ClientImage.denormalizeReference(image.reference, containerSystemConfig: containerSystemConfig)
                let reference = try ContainerizationOCI.Reference.parse(processedReferenceString)
                for descriptor in try await image.index().manifests {
                    if let referenceType = descriptor.annotations?["vnd.docker.reference.type"],
                        referenceType == "attestation-manifest"
                    {
                        continue
                    }

                    guard let platform = descriptor.platform else {
                        continue
                    }

                    var config: ContainerizationOCI.Image
                    var manifest: ContainerizationOCI.Manifest
                    do {
                        config = try await image.config(for: platform)
                        manifest = try await image.manifest(for: platform)
                    } catch {
                        continue
                    }

                    let created = config.created ?? ""
                    let size = descriptor.size + manifest.config.size + manifest.layers.reduce(0) { $0 + $1.size }
                    let formattedSize = formatter.string(fromByteCount: size)

                    items.append(
                        VerboseImageRow(
                            name: reference.name,
                            tag: reference.tag ?? "<none>",
                            indexDigest: Utility.trimDigest(digest: imageDigest),
                            os: platform.os,
                            arch: platform.architecture,
                            variant: platform.variant ?? "",
                            fullSize: formattedSize,
                            created: created,
                            manifestDigest: Utility.trimDigest(digest: descriptor.digest)
                        ))
                }
            }
            return items
        }

        struct PrintableImage: Codable {
            let reference: String
            let fullSize: String
            let descriptor: Descriptor
        }
    }
}

private struct ImageRow: ListDisplayable {
    let name: String
    let tag: String
    let trimmedDigest: String

    static var tableHeader: [String] {
        ["NAME", "TAG", "DIGEST"]
    }

    var tableRow: [String] {
        [name, tag, trimmedDigest]
    }

    // Required by ListDisplayable but unused — ImageList handles quiet mode
    // separately to avoid expensive digest resolution.
    var quietValue: String {
        name
    }
}

private struct VerboseImageRow: ListDisplayable {
    let name: String
    let tag: String
    let indexDigest: String
    let os: String
    let arch: String
    let variant: String
    let fullSize: String
    let created: String
    let manifestDigest: String

    static var tableHeader: [String] {
        ["NAME", "TAG", "INDEX DIGEST", "OS", "ARCH", "VARIANT", "FULL SIZE", "CREATED", "MANIFEST DIGEST"]
    }

    var tableRow: [String] {
        [name, tag, indexDigest, os, arch, variant, fullSize, created, manifestDigest]
    }

    var quietValue: String {
        name
    }
}
