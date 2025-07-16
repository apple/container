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
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import SwiftProtobuf

extension Application {
    struct ListImageOptions: ParsableArguments {
        @Flag(name: .shortAndLong, help: "Only output the image name")
        var quiet = false

        @Flag(name: .shortAndLong, help: "Verbose output")
        var verbose = false

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @OptionGroup
        var global: Flags.Global
    }

    struct ListImageImplementation {
        static private func createHeader() -> [[String]] {
            [["NAME", "TAG", "DIGEST"]]
        }

        static private func createVerboseHeader() -> [[String]] {
            [["NAME", "TAG", "INDEX DIGEST", "OS", "ARCH", "VARIANT", "SIZE", "CREATED", "MANIFEST DIGEST"]]
        }

        static private func printImagesVerbose(images: [ClientImage]) async throws {

            var rows = createVerboseHeader()
            for image in images {
                let formatter = ByteCountFormatter()
                for descriptor in try await image.index().manifests {
                    // Don't list attestation manifests
                    if let referenceType = descriptor.annotations?["vnd.docker.reference.type"],
                        referenceType == "attestation-manifest"
                    {
                        continue
                    }

                    guard let platform = descriptor.platform else {
                        continue
                    }

                    let os = platform.os
                    let arch = platform.architecture
                    let variant = platform.variant ?? ""

                    var config: ContainerizationOCI.Image
                    var manifest: ContainerizationOCI.Manifest
                    do {
                        config = try await image.config(for: platform)
                        manifest = try await image.manifest(for: platform)
                    } catch {
                        continue
                    }

                    let created = config.created ?? ""
                    let size = descriptor.size + manifest.config.size + manifest.layers.reduce(0, { (l, r) in l + r.size })
                    let formattedSize = formatter.string(fromByteCount: size)

                    let processedReferenceString = try ClientImage.denormalizeReference(image.reference)
                    let reference = try ContainerizationOCI.Reference.parse(processedReferenceString)
                    let row = [
                        reference.name,
                        reference.tag ?? "<none>",
                        Utility.trimDigest(digest: image.descriptor.digest),
                        os,
                        arch,
                        variant,
                        formattedSize,
                        created,
                        Utility.trimDigest(digest: descriptor.digest),
                    ]
                    rows.append(row)
                }
            }

            let formatter = TableOutput(rows: rows)
            print(formatter.format())
        }

        static private func printImages(images: [ClientImage], format: ListFormat, options: ListImageOptions) async throws {
            var images = images
            images.sort {
                $0.reference < $1.reference
            }

            if format == .json {
                let data = try JSONEncoder().encode(images.map { $0.description })
                print(String(data: data, encoding: .utf8)!)
                return
            }

            if options.quiet {
                try images.forEach { image in
                    let processedReferenceString = try ClientImage.denormalizeReference(image.reference)
                    print(processedReferenceString)
                }
                return
            }

            if options.verbose {
                try await Self.printImagesVerbose(images: images)
                return
            }

            var rows = createHeader()
            for image in images {
                let processedReferenceString = try ClientImage.denormalizeReference(image.reference)
                let reference = try ContainerizationOCI.Reference.parse(processedReferenceString)
                rows.append([
                    reference.name,
                    reference.tag ?? "<none>",
                    Utility.trimDigest(digest: image.descriptor.digest),
                ])
            }
            let formatter = TableOutput(rows: rows)
            print(formatter.format())
        }

        static func validate(options: ListImageOptions) throws {
            if options.quiet && options.verbose {
                throw ContainerizationError(.invalidArgument, message: "Cannot use flag --quite and --verbose together")
            }
            let modifier = options.quiet || options.verbose
            if modifier && options.format == .json {
                throw ContainerizationError(.invalidArgument, message: "Cannot use flag --quite or --verbose along with --format json")
            }
        }

        static func listImages(options: ListImageOptions) async throws {
            let images = try await ClientImage.list().filter { img in
                !Utility.isInfraImage(name: img.reference)
            }
            try await printImages(images: images, format: options.format, options: options)
        }
    }

    struct ImageList: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List images",
            aliases: ["ls"])

        @OptionGroup
        var options: ListImageOptions

        mutating func run() async throws {
            try ListImageImplementation.validate(options: options)
            try await ListImageImplementation.listImages(options: options)
        }
    }
}
