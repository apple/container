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

import ContainerAPIClient
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerCommands

struct ImageListTests {
    private let healthy = "example.invalid/healthy:latest"
    private let healthyAfterBroken = "example.invalid/healthy-after-broken:latest"
    private let broken = "example.invalid/broken:latest"

    private func image(_ reference: String) -> ClientImage {
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json",
            digest: "sha256:" + String(repeating: "a", count: 64),
            size: 1
        )
        return ClientImage(description: ImageDescription(reference: reference, descriptor: descriptor))
    }

    private func resource(for image: ClientImage) -> ImageResource {
        ImageResource(
            configuration: .init(description: image.description, creationDate: Date(timeIntervalSince1970: 0)),
            variants: [],
            displayReference: image.reference
        )
    }

    @Test(arguments: [ListFormat.table, .json, .yaml, .toml])
    func partialListingRendersHealthyImageAndReportsFailure(format: ListFormat) async throws {
        let images = [image(healthy), image(broken), image(healthyAfterBroken)]
        var output: [String] = []
        var warnings: [String] = []

        do {
            try await Application.ImageList.renderImages(
                images: images,
                format: format,
                verbose: false,
                resolve: { image in
                    if image.reference == broken {
                        throw ContainerizationError(.notFound, message: "missing content blob")
                    }
                    return resource(for: image)
                },
                onError: { image, error in
                    warnings.append("\(image.reference): \(error)")
                },
                emit: { output.append($0) }
            )
            Issue.record("partial listing should fail")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.invalidState))
            #expect(error.message.contains("1 image"))
        }

        let rendered = try #require(output.first)
        #expect(output.count == 1)
        #expect(rendered.contains(format == .table ? "healthy" : healthy))
        #expect(rendered.contains(format == .table ? "healthy-after-broken" : healthyAfterBroken))
        if format == .table {
            #expect(rendered.split(separator: "\n").count == 3)
        } else {
            #expect(!rendered.contains(broken))
        }
        let warning = try #require(warnings.first)
        #expect(warnings.count == 1)
        #expect(warning.contains(broken))
        #expect(warning.contains("missing content blob"))

        if format == .json {
            let parsed = try #require(JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [[String: Any]])
            #expect(parsed.count == 2)
        }
    }

    @Test
    func healthyListingSucceedsWithoutWarnings() async throws {
        var output: [String] = []
        var warnings: [String] = []

        try await Application.ImageList.renderImages(
            images: [image(healthy)],
            format: .json,
            verbose: false,
            resolve: { image in resource(for: image) },
            onError: { image, _ in warnings.append(image.reference) },
            emit: { output.append($0) }
        )

        let rendered = try #require(output.first)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [[String: Any]])
        #expect(output.count == 1)
        #expect(parsed.count == 1)
        #expect(warnings.isEmpty)
    }

    @Test
    func allUnreadableImagesRenderEmptyJSONAndReportFailure() async throws {
        var output: [String] = []
        var warnings: [String] = []

        do {
            try await Application.ImageList.renderImages(
                images: [image(broken)],
                format: .json,
                verbose: false,
                resolve: { _ in
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "corrupt index"))
                },
                onError: { image, _ in warnings.append(image.reference) },
                emit: { output.append($0) }
            )
            Issue.record("unreadable listing should fail")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.invalidState))
        }

        #expect(output == ["[]"])
        #expect(warnings == [broken])
    }

    @Test
    func serviceFailureIsNotTreatedAsUnreadableImage() async throws {
        var output: [String] = []
        var warnings: [String] = []

        do {
            try await Application.ImageList.renderImages(
                images: [image(healthy), image(broken)],
                format: .json,
                verbose: false,
                resolve: { image in
                    if image.reference == broken {
                        throw ContainerizationError(.interrupted, message: "image service unavailable")
                    }
                    return resource(for: image)
                },
                onError: { image, _ in warnings.append(image.reference) },
                emit: { output.append($0) }
            )
            Issue.record("service failure should propagate")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.interrupted))
        }

        #expect(output.isEmpty)
        #expect(warnings.isEmpty)
    }
}
