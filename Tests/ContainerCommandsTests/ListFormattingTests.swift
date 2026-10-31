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

import ContainerCommands
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

// MARK: - ManagedContainer conformance tests

struct ManagedContainerDisplayTests {
    @Test
    func tableHeaderHasNineColumns() {
        #expect(ManagedContainer.tableHeader.count == 9)
        #expect(ManagedContainer.tableHeader[0] == "ID")
        #expect(ManagedContainer.tableHeader[4] == "STATE")
        #expect(ManagedContainer.tableHeader[8] == "STARTED")
    }
}

// MARK: - NetworkResource ListDisplayable conformance tests

struct NetworkResourceDisplayTests {
    @Test
    func tableHeaderHasTwoColumns() {
        #expect(NetworkResource.tableHeader.count == 2)
        #expect(NetworkResource.tableHeader == ["NETWORK", "SUBNET"])
    }
}

// MARK: - ImageResource ListDisplayable conformance tests

struct ImageResourceDisplayTests {
    @Test
    func tableHeaderIncludesDiskUsage() {
        #expect(ImageResource.tableHeader == ["NAME", "TAG", "DIGEST", "DISK USAGE"])
    }

    @Test
    func tableRowIncludesDiskUsage() {
        let resource = makeImageResource(variants: [
            .init(platform: try! Platform(from: "linux/arm64"), digest: "sha256:manifest1", size: 1024, config: makeImageConfig()),
            .init(platform: try! Platform(from: "linux/amd64"), digest: "sha256:manifest2", size: 2048, config: makeImageConfig()),
        ])

        #expect(resource.tableRow == ["alpine", "latest", "abcdef123456", formattedByteCount(3072)])
    }

    @Test
    func diskUsageSkipsUnknownPlatformAttestations() {
        let resource = makeImageResource(variants: [
            .init(platform: try! Platform(from: "linux/arm64"), digest: "sha256:manifest1", size: 1024, config: makeImageConfig()),
            .init(platform: Platform(arch: "unknown", os: "unknown"), digest: "sha256:attestation", size: 2048, config: makeImageConfig()),
        ])

        #expect(resource.tableRow.last == formattedByteCount(1024))
    }

    private func makeImageResource(variants: [ImageResource.Variant]) -> ImageResource {
        ImageResource(
            configuration: .init(
                description: .init(
                    reference: "docker.io/library/alpine:latest",
                    descriptor: .init(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abcdef123456", size: 42)
                ),
                creationDate: Date(timeIntervalSince1970: 0)
            ),
            variants: variants,
            displayReference: "alpine:latest"
        )
    }

    private func makeImageConfig() -> ContainerizationOCI.Image {
        .init(architecture: "arm64", os: "linux", rootfs: .init(type: "layers", diffIDs: []))
    }

    private func formattedByteCount(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        return formatter.string(fromByteCount: value)
    }
}

// MARK: - ListFormat tests

struct ListFormatTests {
    @Test
    func hasAllOutputFormatCases() {
        #expect(ListFormat.allCases.count == 4)
        #expect(ListFormat.json.rawValue == "json")
        #expect(ListFormat.table.rawValue == "table")
        #expect(ListFormat.yaml.rawValue == "yaml")
        #expect(ListFormat.toml.rawValue == "toml")
    }
}
