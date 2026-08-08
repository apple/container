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

struct FilesystemSMBTests {

    @Test("SMB factory produces correct FSType")
    func testSMBFactory() {
        let fs = Filesystem.smb(
            share: "//server/share",
            mountOptions: ["username": "user", "password": "secret"],
            destination: "/data",
            options: []
        )

        guard case .smb(let share, let opts) = fs.type else {
            Issue.record("Expected .smb FSType")
            return
        }
        #expect(share == "//server/share")
        #expect(opts["username"] == "user")
        #expect(opts["password"] == "secret")
        #expect(fs.source == "//server/share")
        #expect(fs.destination == "/data")
    }

    @Test("isSMB returns true only for SMB filesystems")
    func testIsSMB() {
        let smb = Filesystem.smb(
            share: "//server/share",
            mountOptions: [:],
            destination: "/data",
            options: []
        )
        let virtiofs = Filesystem.virtiofs(source: "/host/path", destination: "/data", options: [])
        let tmpfs = Filesystem.tmpfs(destination: "/tmp", options: [])

        #expect(smb.isSMB)
        #expect(!virtiofs.isSMB)
        #expect(!tmpfs.isSMB)
    }

    @Test("SMB filesystem is not a block device")
    func testSMBIsNotBlock() {
        let fs = Filesystem.smb(
            share: "//server/share",
            mountOptions: [:],
            destination: "/data",
            options: []
        )
        #expect(!fs.isBlock)
        #expect(!fs.isVolume)
        #expect(!fs.isTmpfs)
        #expect(!fs.isVirtiofs)
    }

    @Test("SMB FSType round-trips through Codable")
    func testSMBCodable() throws {
        let original = Filesystem.smb(
            share: "//server/share",
            mountOptions: ["username": "user", "domain": "corp"],
            destination: "/mnt/data",
            options: ["ro"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Filesystem.self, from: data)

        guard case .smb(let share, let opts) = decoded.type else {
            Issue.record("Expected .smb after decoding")
            return
        }
        #expect(share == "//server/share")
        #expect(opts["username"] == "user")
        #expect(opts["domain"] == "corp")
        #expect(decoded.destination == "/mnt/data")
        #expect(decoded.options == ["ro"])
    }

    @Test("SMB mount options are preserved with extra options")
    func testSMBWithExtraOptions() {
        let fs = Filesystem.smb(
            share: "//nas/backup",
            mountOptions: ["username": "admin", "password": "pass", "domain": "corp"],
            destination: "/backup",
            options: ["ro", "noatime"]
        )

        guard case .smb(_, let opts) = fs.type else {
            Issue.record("Expected .smb FSType")
            return
        }
        #expect(opts.count == 3)
        #expect(fs.options == ["ro", "noatime"])
    }
}
