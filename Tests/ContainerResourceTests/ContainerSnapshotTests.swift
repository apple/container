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

import Foundation
import Testing

@testable import ContainerResource

/// Tests for `ContainerSnapshot` exit-code/exit-date fields.
///
/// We avoid hand-constructing `ContainerConfiguration` here (its
/// initializer surface is large and tangential to what we're testing);
/// instead we drive everything through JSON, which is the actual on-the-wire
/// contract for inspect/list and the place backward-compat matters.
struct ContainerSnapshotTests {

    /// A minimal `ContainerConfiguration` JSON payload that the decoder
    /// accepts. Field set kept to the minimum the decoder demands; the
    /// content is irrelevant to these tests.
    private static let fixtureConfigJSON = """
        {
          "id": "test-container",
          "image": {
            "reference": "alpine:latest",
            "descriptor": {
              "mediaType": "application/vnd.oci.image.index.v1+json",
              "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
              "size": 0
            }
          },
          "platform": { "os": "linux", "architecture": "arm64" },
          "labels": {},
          "useInit": false,
          "sysctls": {},
          "publishedPorts": [],
          "networks": [],
          "publishedSockets": [],
          "capAdd": [],
          "capDrop": [],
          "readOnly": false,
          "rosetta": false,
          "ssh": false,
          "virtualization": false,
          "runtimeHandler": "container-runtime-linux",
          "resources": { "cpus": 1, "memoryInBytes": 1073741824 },
          "initProcess": {
            "rlimits": [],
            "terminal": false,
            "workingDirectory": "/",
            "environment": [],
            "arguments": [],
            "executable": "/bin/sh",
            "user": { "id": { "uid": 0, "gid": 0 } },
            "supplementalGroups": []
          },
          "mounts": []
        }
        """

    private func snapshotJSON(extraFields: String = "") -> Data {
        let json = """
            {
              "configuration": \(Self.fixtureConfigJSON),
              "status": "stopped",
              "networks": [],
              "startedDate": null\(extraFields)
            }
            """
        return Data(json.utf8)
    }

    /// Backward-compat: snapshots written by older daemons that lack
    /// `exitCode`/`exitedDate` must still decode, with both fields nil.
    @Test("Legacy snapshot JSON decodes with nil exit fields")
    func testLegacySnapshotDecodes() throws {
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ContainerSnapshot.self, from: snapshotJSON())
        #expect(decoded.status == .stopped)
        #expect(decoded.exitCode == nil)
        #expect(decoded.exitedDate == nil)
    }

    /// Forward path: a snapshot with exit fields populated decodes them
    /// and survives a round-trip through JSON unchanged.
    @Test("Snapshot with exit fields round-trips through JSON")
    func testExitFieldsRoundTrip() throws {
        let extra = """
            ,
              "exitCode": 42,
              "exitedDate": 1000000
            """
        let payload = snapshotJSON(extraFields: extra)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ContainerSnapshot.self, from: payload)

        #expect(decoded.exitCode == 42)
        #expect(decoded.exitedDate?.timeIntervalSince1970 == 1_000_000)

        // Re-encode and decode again — same values.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let reEncoded = try encoder.encode(decoded)
        let reDecoded = try decoder.decode(ContainerSnapshot.self, from: reEncoded)

        #expect(reDecoded.exitCode == 42)
        #expect(reDecoded.exitedDate?.timeIntervalSince1970 == 1_000_000)
    }

    /// Non-zero exit codes (137 = SIGKILL, 255 = generic error) must
    /// preserve sign and magnitude. The field is Int32, not UInt8 —
    /// guard against future schema regressions narrowing the type.
    @Test("Non-zero exit codes preserved across the type's Int32 range")
    func testExitCodeRange() throws {
        let decoder = JSONDecoder()
        for code in [0, 1, 42, 127, 137, 255, -1] {
            let payload = snapshotJSON(extraFields: ",\n  \"exitCode\": \(code)")
            let decoded = try decoder.decode(ContainerSnapshot.self, from: payload)
            #expect(decoded.exitCode == Int32(code), "exitCode \(code) should round-trip")
        }
    }
}
