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

import ArgumentParser
import Foundation
import Testing

@testable import ContainerCommands

struct VolumeCreateTests {
    private typealias VolumeCreate = Application.VolumeCommand.VolumeCreate

    @Test("volume create parses --password-stdin and leaves it off by default")
    func testParsesPasswordStdin() throws {
        let withFlag = try VolumeCreate.parse(["--driver", "smb", "--opt", "share=//server/share", "--password-stdin", "myshare"])
        #expect(withFlag.passwordStdin)

        let withoutFlag = try VolumeCreate.parse(["--driver", "smb", "--opt", "share=//server/share", "myshare"])
        #expect(!withoutFlag.passwordStdin)
    }

    @Test(
        "the password read from stdin loses only its trailing line ending",
        arguments: [
            ("secret", "secret"),
            ("secret\n", "secret"),
            ("secret\r\n", "secret"),
            ("secret\n\n", "secret"),
            ("p@ss=w0rd\n", "p@ss=w0rd"),
            // Other whitespace is kept so the option validator rejects it instead of the password changing.
            (" secret \n", " secret "),
            ("sec\nret\n", "sec\nret"),
        ]
    )
    func testPasswordFromStdin(_ input: String, _ expected: String) throws {
        #expect(try VolumeCreate.password(fromStdin: Data(input.utf8)) == expected)
    }

    @Test("an empty or unreadable password from stdin is rejected", arguments: [Data?.none, Data(), Data("\n".utf8), Data("\r\n".utf8), Data([0xff, 0xfe])])
    func testRejectsEmptyOrUnreadablePassword(_ input: Data?) throws {
        #expect(throws: ValidationError.self) {
            try VolumeCreate.password(fromStdin: input)
        }
    }

    @Test("--password-stdin is accepted for an smb volume with a username")
    func testPasswordStdinAcceptedForSMB() throws {
        try VolumeCreate.validatePasswordStdin(driver: "smb", driverOpts: ["share": "//server/share", "username": "alice"])
    }

    @Test("--password-stdin is rejected for drivers other than smb", arguments: ["local", "nfs"])
    func testPasswordStdinRejectedForOtherDrivers(_ driver: String) throws {
        #expect(throws: ValidationError.self) {
            try VolumeCreate.validatePasswordStdin(driver: driver, driverOpts: ["share": "server:/export", "username": "alice"])
        }
    }

    @Test("--password-stdin cannot be combined with --opt password=")
    func testPasswordStdinConflictsWithPasswordOption() throws {
        #expect(throws: ValidationError.self) {
            try VolumeCreate.validatePasswordStdin(
                driver: "smb",
                driverOpts: ["share": "//server/share", "username": "alice", "password": "secret"]
            )
        }
    }

    @Test("--password-stdin requires a username", arguments: [["share": "//server/share"], ["share": "//server/share", "username": ""]])
    func testPasswordStdinRequiresUsername(_ driverOpts: [String: String]) throws {
        #expect(throws: ValidationError.self) {
            try VolumeCreate.validatePasswordStdin(driver: "smb", driverOpts: driverOpts)
        }
    }
}
