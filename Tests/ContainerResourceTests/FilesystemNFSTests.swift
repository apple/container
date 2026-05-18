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

struct FilesystemNFSTests {

    @Test("NFS factory produces correct FSType")
    func testNFSFactory() {
        let fs = Filesystem.nfs(
            share: "nas.local:/exports/data",
            mountOptions: ["vers": "4"],
            destination: "/data",
            options: []
        )

        guard case .nfs(let share, let opts) = fs.type else {
            Issue.record("Expected .nfs FSType")
            return
        }
        #expect(share == "nas.local:/exports/data")
        #expect(opts["vers"] == "4")
        #expect(fs.source == "nas.local:/exports/data")
        #expect(fs.destination == "/data")
    }

    @Test("isNFS returns true only for NFS filesystems")
    func testIsNFS() {
        let nfs = Filesystem.nfs(
            share: "nas.local:/exports/data",
            mountOptions: [:],
            destination: "/data",
            options: []
        )
        let virtiofs = Filesystem.virtiofs(source: "/host/path", destination: "/data", options: [])
        let tmpfs = Filesystem.tmpfs(destination: "/tmp", options: [])

        #expect(nfs.isNFS)
        #expect(!virtiofs.isNFS)
        #expect(!tmpfs.isNFS)
    }

    @Test("NFS filesystem is not a block device")
    func testNFSIsNotBlock() {
        let fs = Filesystem.nfs(
            share: "nas.local:/exports/data",
            mountOptions: [:],
            destination: "/data",
            options: []
        )
        #expect(!fs.isBlock)
        #expect(!fs.isVolume)
        #expect(!fs.isTmpfs)
        #expect(!fs.isVirtiofs)
        #expect(!fs.isSMB)
    }

    @Test("NFS FSType round-trips through Codable")
    func testNFSCodable() throws {
        let original = Filesystem.nfs(
            share: "nas.local:/exports/data",
            mountOptions: ["vers": "4"],
            destination: "/mnt/data",
            options: ["ro"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Filesystem.self, from: data)

        guard case .nfs(let share, let opts) = decoded.type else {
            Issue.record("Expected .nfs after decoding")
            return
        }
        #expect(share == "nas.local:/exports/data")
        #expect(opts["vers"] == "4")
        #expect(decoded.destination == "/mnt/data")
        #expect(decoded.options == ["ro"])
    }

    @Test("NFS mount options are preserved with extra options")
    func testNFSWithExtraOptions() {
        let fs = Filesystem.nfs(
            share: "nas.local:/exports/backup",
            mountOptions: ["vers": "3", "timeo": "600"],
            destination: "/backup",
            options: ["ro", "noatime"]
        )

        guard case .nfs(_, let opts) = fs.type else {
            Issue.record("Expected .nfs FSType")
            return
        }
        #expect(opts.count == 2)
        #expect(fs.options == ["ro", "noatime"])
    }
}
