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

import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Testing

@testable import ContainerAPIService
import ContainerResource

struct ContainerExitStatusTests {

    @Test("Container exit status is stamped onto the stopped snapshot")
    func testExitStatusIsStampedOntoStoppedSnapshot() throws {
        var snapshot = makeContainerSnapshot(
            status: RuntimeStatus.running,
            networks: [try makeAttachment()],
            lastExitCode: nil
        )

        ContainersService.markSnapshotStopped(&snapshot, exitStatus: ExitStatus(exitCode: 42))

        #expect(snapshot.status == RuntimeStatus.stopped)
        #expect(snapshot.lastExitCode == 42)
        #expect(snapshot.networks.isEmpty)
    }

    @Test("Missing exit status clears lastExitCode on the stopped snapshot")
    func testMissingExitStatusClearsLastExitCode() throws {
        var snapshot = makeContainerSnapshot(
            status: RuntimeStatus.running,
            networks: [try makeAttachment()],
            lastExitCode: 1
        )

        ContainersService.markSnapshotStopped(&snapshot, exitStatus: nil)

        #expect(snapshot.status == RuntimeStatus.stopped)
        #expect(snapshot.lastExitCode == nil)
        #expect(snapshot.networks.isEmpty)
    }

    private func makeContainerSnapshot(
        status: RuntimeStatus,
        networks: [ContainerResource.Attachment],
        lastExitCode: Int32?
    ) -> ContainerSnapshot {
        ContainerSnapshot(
            configuration: makeContainerConfiguration(),
            status: status,
            networks: networks,
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

    private func makeAttachment() throws -> ContainerResource.Attachment {
        ContainerResource.Attachment(
            network: "test-network",
            hostname: "test-container",
            ipv4Address: try CIDRv4("192.168.64.2/24"),
            ipv4Gateway: try IPv4Address("192.168.64.1"),
            ipv6Address: nil,
            macAddress: nil
        )
    }
}
