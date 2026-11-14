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

import ContainerTestSupport
import ContainerizationArchive
import CryptoKit
import Foundation
import Testing

struct TestCLIImageLoadZstd {
    @Test func testLoadZstdLayerAtEOF() async throws {
        try await ContainerFixture.with { f in
            let reference = "registry.local/\(f.testID)/zstd-eof:latest"
            f.addCleanup { try? f.doRemoveImages([reference]) }
            let layout = URL(filePath: f.testDir.appending("layout").string)
            let blobs = layout.appendingPathComponent("blobs/sha256")
            try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)

            // zstd 1.5.7, level 3, of a USTAR header for hello.txt (mode 0644,
            // uid/gid/mtime 0, size 6) followed by "hello\n" padded to 512 bytes.
            // There are no terminal tar zero blocks: unpack must reach zstd EOF.
            var layer = try #require(
                Data(base64Encoded: "KLUv/WAAA10CAHQCaGVsbG8udHh0ADAwMDA2NDQwMDAAMDA3NjA1ACAwAHVzdGFyADAKDABkuQoQjqEbINqAAAXEG1IDQDpuxc+HoFYAcKxc5iaABA=="))
            // A skippable metadata frame, as used by zstd:chunked layers.
            layer.append(contentsOf: [0x50, 0x2a, 0x4d, 0x18, 4, 0, 0, 0, 0, 0, 0, 0])

            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "amd64"
            #endif
            let config: [String: Any] = [
                "architecture": architecture,
                "os": "linux",
                "config": [String: String](),
                "rootfs": ["type": "layers", "diff_ids": ["sha256:5367913cabddaea6f1fd5fc74382598cfaac43cdf028798d36615b3ed17728fe"]],
            ]
            let configDescriptor = try writeBlob(JSONSerialization.data(withJSONObject: config), mediaType: "application/vnd.oci.image.config.v1+json", in: blobs)
            let layerDescriptor = try writeBlob(layer, mediaType: "application/vnd.oci.image.layer.v1.tar+zstd", in: blobs)
            let manifest: [String: Any] = [
                "schemaVersion": 2,
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "config": configDescriptor,
                "layers": [layerDescriptor],
            ]
            var manifestDescriptor = try writeBlob(
                JSONSerialization.data(withJSONObject: manifest), mediaType: "application/vnd.oci.image.manifest.v1+json", in: blobs)
            manifestDescriptor["platform"] = ["os": "linux", "architecture": architecture]
            manifestDescriptor["annotations"] = ["org.opencontainers.image.ref.name": reference]
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "manifests": [manifestDescriptor]])
                .write(to: layout.appendingPathComponent("index.json"))
            try Data("{\"imageLayoutVersion\":\"1.0.0\"}".utf8).write(to: layout.appendingPathComponent("oci-layout"))

            let archive = f.testDir.appending("zstd-eof.tar")
            let writer = try ArchiveWriter(format: .pax, filter: .none, file: URL(filePath: archive.string))
            try writer.archiveDirectory(layout)
            try writer.finishEncoding()

            try f.run(["image", "load", "--input", archive.string]).check("loading a complete zstd stream failed")
            #expect(try f.isImagePresent(reference))
            let inspected = try f.doInspectImages(reference)
            #expect(inspected.count == 1)
            #expect(inspected[0].variants.count == 1)
        }
    }

    private func writeBlob(_ data: Data, mediaType: String, in directory: URL) throws -> [String: Any] {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try data.write(to: directory.appendingPathComponent(digest))
        return ["mediaType": mediaType, "digest": "sha256:\(digest)", "size": data.count]
    }
}
