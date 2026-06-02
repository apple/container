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
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation

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
            let containerSystemConfig: ContainerSystemConfig = try await Application.loadContainerSystemConfig()
            try Self.validate(quiet: quiet, verbose: verbose)

            var images = try await ClientImage.list().filter { img in
                !Utility.isInfraImage(name: img.reference, builderImage: containerSystemConfig.build.image, initImage: containerSystemConfig.vminit.image)
            }
            images.sort { $0.reference < $1.reference }

            // Quiet mode prints references directly and skips the more expensive
            // per-image manifest resolution. `--format json` takes precedence.
            if quiet && format != .json {
                for image in images {
                    let processedReferenceString = try ClientImage.denormalizeReference(image.reference, containerSystemConfig: containerSystemConfig)
                    print(processedReferenceString)
                }
                return
            }

            let resources = try await Self.buildResources(images: images, containerSystemConfig: containerSystemConfig)

            if format == .json {
                try Self.emitJSON(resources: resources)
                return
            }

            if verbose {
                let rows = resources.flatMap { VerboseImageRow.rows(for: $0) }
                Output.emit(Output.renderTable(rows))
                return
            }

            Output.emit(Output.renderTable(resources))
        }

        private static func validate(quiet: Bool, verbose: Bool) throws {
            if quiet && verbose {
                throw ContainerizationError(.invalidArgument, message: "cannot use flag --quiet and --verbose together")
            }
        }

        /// Builds the resource for each image, denormalizing the reference so the
        /// display name omits the default registry.
        private static func buildResources(images: [ClientImage], containerSystemConfig: ContainerSystemConfig) async throws -> [ImageResource] {
            var resources: [ImageResource] = []
            for image in images {
                let resolved = try await image.resolvedManifests()
                let displayReference = try ClientImage.denormalizeReference(image.reference, containerSystemConfig: containerSystemConfig)
                resources.append(
                    ImageResource(config: image.description, index: resolved.index, manifests: resolved.manifests, displayReference: displayReference))
            }
            return resources
        }

        private static func emitJSON(resources: [ImageResource]) throws {
            let options = JSONOptions(dateEncodingStrategy: .iso8601)
            try Output.emit(Output.renderJSON(resources, options: options))
        }
    }
}

/// A single row of the verbose image listing — one per platform variant.
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

    /// Flattens an ImageResource into one verbose image row entry per platform variant.
    static func rows(for resource: ImageResource) -> [VerboseImageRow] {
        let formatter = ByteCountFormatter()
        let reference = try? ContainerizationOCI.Reference.parse(resource.displayReference)
        let name = reference?.name ?? resource.displayReference
        let tag = reference?.tag ?? "<none>"
        let indexDigest = Utility.trimDigest(digest: resource.index.digest)
        return
            resource.variants
            // Skip attestation manifests, which use the `unknown/unknown` platform.
            .filter { !($0.platform.os == "unknown" && $0.platform.architecture == "unknown") }
            .map { variant in
                VerboseImageRow(
                    name: name,
                    tag: tag,
                    indexDigest: indexDigest,
                    os: variant.platform.os,
                    arch: variant.platform.architecture,
                    variant: variant.platform.variant ?? "",
                    fullSize: formatter.string(fromByteCount: variant.size),
                    created: variant.config.created ?? "",
                    manifestDigest: Utility.trimDigest(digest: variant.digest)
                )
            }
    }
}
