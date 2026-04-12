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

struct SMBVolumeTests {

    // MARK: - Parser: named volume syntax still works for SMB volumes

    @Test("Named volume syntax resolves as a volume, not a filesystem")
    func testNamedVolumeIsParsedAsVolume() throws {
        let result = try Parser.volume("myshare:/data")
        guard case .volume(let parsed) = result else {
            Issue.record("Expected .volume, got .filesystem")
            return
        }
        #expect(parsed.name == "myshare")
        #expect(parsed.destination == "/data")
        #expect(!parsed.isAnonymous)
    }

    @Test("Named volume with options is parsed correctly")
    func testNamedVolumeWithOptions() throws {
        let result = try Parser.volume("myshare:/data:ro")
        guard case .volume(let parsed) = result else {
            Issue.record("Expected .volume")
            return
        }
        #expect(parsed.name == "myshare")
        #expect(parsed.destination == "/data")
        #expect(parsed.options == ["ro"])
    }

    // MARK: - Volume model: SMB driver fields

    @Test("SMB volume stores share path as source")
    func testSMBVolumeSource() {
        let volume = Volume(
            name: "myshare",
            driver: "smb",
            format: "cifs",
            source: "//server/share",
            labels: [:],
            options: ["username": "user", "password": "secret"],
            sizeInBytes: nil
        )

        #expect(volume.driver == "smb")
        #expect(volume.format == "cifs")
        #expect(volume.source == "//server/share")
        #expect(volume.sizeInBytes == nil)
        #expect(volume.options["username"] == "user")
        #expect(volume.options["password"] == "secret")
    }

    @Test("SMB volume is not anonymous")
    func testSMBVolumeIsNotAnonymous() {
        let volume = Volume(
            name: "myshare",
            driver: "smb",
            format: "cifs",
            source: "//server/share",
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

    // MARK: - Utility: parseKeyValuePairs for SMB driver opts

    @Test("SMB driver opts are parsed from --opt flags")
    func testSMBDriverOptsKeyValueParsing() {
        let raw = ["share=//server/share", "username=user", "password=secret", "domain=corp"]
        let parsed = Utility.parseKeyValuePairs(raw)

        #expect(parsed["share"] == "//server/share")
        #expect(parsed["username"] == "user")
        #expect(parsed["password"] == "secret")
        #expect(parsed["domain"] == "corp")
    }

    @Test("Missing share opt is detectable")
    func testMissingSMBShareOpt() {
        let opts = Utility.parseKeyValuePairs(["username=user"])
        #expect(opts["share"] == nil)
    }
}
