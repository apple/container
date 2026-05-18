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

import ContainerResource
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIClient

struct NFSVolumeTests {

    // MARK: - Parser: named volume syntax still works for NFS volumes

    @Test("Named volume syntax resolves as a volume, not a filesystem")
    func testNamedVolumeIsParsedAsVolume() throws {
        let result = try Parser.volume("myexport:/data")
        guard case .volume(let parsed) = result else {
            Issue.record("Expected .volume, got .filesystem")
            return
        }
        #expect(parsed.name == "myexport")
        #expect(parsed.destination == "/data")
        #expect(!parsed.isAnonymous)
    }

    @Test("Named volume with options is parsed correctly")
    func testNamedVolumeWithOptions() throws {
        let result = try Parser.volume("myexport:/data:ro")
        guard case .volume(let parsed) = result else {
            Issue.record("Expected .volume")
            return
        }
        #expect(parsed.name == "myexport")
        #expect(parsed.destination == "/data")
        #expect(parsed.options == ["ro"])
    }

    // MARK: - Volume model: NFS driver fields

    @Test("NFS volume stores share path as source")
    func testNFSVolumeSource() {
        let volume = Volume(
            name: "myexport",
            driver: "nfs",
            format: "nfs",
            source: "nas.local:/exports/data",
            labels: [:],
            options: ["vers": "4"],
            sizeInBytes: nil
        )

        #expect(volume.driver == "nfs")
        #expect(volume.format == "nfs")
        #expect(volume.source == "nas.local:/exports/data")
        #expect(volume.sizeInBytes == nil)
        #expect(volume.options["vers"] == "4")
    }

    @Test("NFS volume is not anonymous")
    func testNFSVolumeIsNotAnonymous() {
        let volume = Volume(
            name: "myexport",
            driver: "nfs",
            format: "nfs",
            source: "nas.local:/exports/data",
            labels: [:]
        )
        #expect(!volume.isAnonymous)
    }

    @Test("Local volume driver defaults remain unchanged")
    func testLocalVolumeDefaults() {
        let volume = Volume(
            name: "mydata",
            source: "/var/lib/container/volumes/mydata/volume.img"
        )
        #expect(volume.driver == "local")
        #expect(volume.format == "ext4")
    }

    // MARK: - Utility: parseKeyValuePairs for NFS driver opts

    @Test("NFS driver opts are parsed from --opt flags")
    func testNFSDriverOptsKeyValueParsing() {
        let raw = ["share=nas.local:/exports/data", "vers=4"]
        let parsed = Utility.parseKeyValuePairs(raw)

        #expect(parsed["share"] == "nas.local:/exports/data")
        #expect(parsed["vers"] == "4")
    }

    @Test("Missing share opt is detectable")
    func testMissingNFSShareOpt() {
        let opts = Utility.parseKeyValuePairs(["vers=4"])
        #expect(opts["share"] == nil)
    }
}
