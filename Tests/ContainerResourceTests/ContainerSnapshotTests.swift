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

import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerResource

struct ContainerSnapshotTests {

    @Test("ContainerSnapshot lastExitCode defaults to nil")
    func testLastExitCodeDefaultsToNil() {
        let snapshot = makeContainerSnapshot()

        #expect(snapshot.lastExitCode == nil)
    }

    @Test("ContainerSnapshot preserves lastExitCode through Codable round trip")
    func testLastExitCodeCodableRoundTrip() throws {
        let original = makeContainerSnapshot(lastExitCode: 137)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContainerSnapshot.self, from: data)

        #expect(decoded.lastExitCode == 137)
        #expect(decoded.id == original.id)
        #expect(decoded.status == original.status)
    }

    @Test("ContainerSnapshot decodes older JSON without lastExitCode")
    func testDecodesOlderJSONWithoutLastExitCode() throws {
        let original = makeContainerSnapshot(lastExitCode: 137)
        let data = try JSONEncoder().encode(original)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.removeValue(forKey: "lastExitCode") != nil)

        let olderData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ContainerSnapshot.self, from: olderData)

        #expect(decoded.lastExitCode == nil)
        #expect(decoded.id == original.id)
        #expect(decoded.status == original.status)
    }

    private func makeContainerSnapshot(lastExitCode: Int32? = nil) -> ContainerSnapshot {
        ContainerSnapshot(
            configuration: makeContainerConfiguration(),
            status: .stopped,
            networks: [],
            startedDate: Date(timeIntervalSince1970: 1_700_000_000),
            lastExitCode: lastExitCode
        )
    }

    private func makeContainerConfiguration() -> ContainerConfiguration {
        ContainerConfiguration(
            id: "test-container",
            image: ImageDescription(
                reference: "example.com/test:latest",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.manifest.v1+json",
                    digest: "sha256:\(String(repeating: "0", count: 64))",
                    size: 0
                )
            ),
            process: ProcessConfiguration(
                executable: "/bin/sh",
                arguments: ["sh"],
                environment: []
            )
        )
    }
}
