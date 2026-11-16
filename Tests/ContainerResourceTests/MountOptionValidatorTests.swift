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
import Testing

struct MountOptionValidatorTests {
    @Test("Accepts typical SMB options")
    func acceptsSMBOptions() throws {
        try MountOptionValidator.validate([
            "share": "//fileserver/share",
            "username": "alice",
            "password": "s3cr3t!#$%",
            "domain": "CORP",
        ])
    }

    @Test("Accepts typical NFS options including bare flags")
    func acceptsNFSOptions() throws {
        try MountOptionValidator.validate([
            "share": "nas.local:/exports/data",
            "addr": "192.168.1.10",
            "vers": "4.1",
            "proto": "tcp",
            "nolock": "",
            "timeo": "600",
        ])
    }

    @Test("Accepts an empty option set")
    func acceptsEmptyOptions() throws {
        try MountOptionValidator.validate([:])
    }

    @Test(
        "Accepts shares with spaces and commas, since the share is the mount source",
        arguments: [
            "//fileserver/My Share",
            "//fileserver/Reports, 2026",
            #"\\fileserver\share"#,
            "nas.local:/exports/my data",
            "[fd00::1]:/exports/data",
        ]
    )
    func acceptsShareSourceCharacters(_ share: String) throws {
        try MountOptionValidator.validateShare(share)
        try MountOptionValidator.validate(["share": share, "username": "user"])
    }

    @Test(
        "Rejects shares that are empty or contain control characters",
        arguments: [
            "",
            "//server/share\u{0}",
            "//server/share\n",
            "//server/\u{1b}[0mshare",
            String(repeating: "s", count: MountOptionValidator.shareLengthMax + 1),
        ]
    )
    func rejectsInvalidShares(_ share: String) {
        #expect(throws: MountOptionValidator.Violation.self) {
            try MountOptionValidator.validateShare(share)
        }
        #expect(throws: MountOptionValidator.Violation.self) {
            try MountOptionValidator.validate(["share": share])
        }
    }

    @Test("Share leniency does not extend to other options")
    func shareLeniencyIsScoped() {
        #expect(throws: MountOptionValidator.Violation.self) {
            try MountOptionValidator.validate(["share": "//server/My Share", "username": "my user"])
        }
    }

    @Test("Accepts keys and values at their maximum length")
    func acceptsMaximumLengths() throws {
        let key = "k" + String(repeating: "a", count: MountOptionValidator.keyLengthMax - 1)
        let value = String(repeating: "v", count: MountOptionValidator.valueLengthMax)
        try MountOptionValidator.validate([key: value])
    }

    @Test(
        "Rejects keys that are malformed or too long",
        arguments: [
            "",
            "1vers",
            "-vers",
            "_vers",
            "ver.s",
            "ver s",
            "ver=s",
            "ver,s",
            "k" + String(repeating: "a", count: MountOptionValidator.keyLengthMax),
        ]
    )
    func rejectsInvalidKeys(_ key: String) {
        #expect(throws: MountOptionValidator.Violation.self) {
            try MountOptionValidator.validate([key: "value"])
        }
    }

    @Test(
        "Rejects values that could inject options or are too long",
        arguments: [
            "a,b",
            "a,uid=0",
            "a b",
            "a\tb",
            "a\nb",
            "\u{0}",
            "a\u{1b}[0m",
            String(repeating: "v", count: MountOptionValidator.valueLengthMax + 1),
        ]
    )
    func rejectsInvalidValues(_ value: String) {
        #expect(throws: MountOptionValidator.Violation.self) {
            try MountOptionValidator.validate(["username": value])
        }
    }

    @Test("Violation names the offending key but not its value")
    func violationOmitsValue() {
        let secret = "hunter2,uid=0"
        do {
            try MountOptionValidator.validate(["password": secret])
            Issue.record("Expected a violation")
        } catch let violation as MountOptionValidator.Violation {
            #expect(violation.description.contains("password"))
            #expect(!violation.description.contains(secret))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Checks options in key order so the first error is deterministic")
    func reportsFirstKeyInOrder() {
        do {
            try MountOptionValidator.validate(["zeta": "a,b", "alpha": "c d"])
            Issue.record("Expected a violation")
        } catch let violation as MountOptionValidator.Violation {
            #expect(violation.description.contains("alpha"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(
        "validateNoSecrets rejects every cifs key that carries or points at a secret",
        arguments: ["password", "pass", "password2", "pass2", "credentials", "cred"]
    )
    func rejectsSecretKeys(_ key: String) {
        do {
            try MountOptionValidator.validateNoSecrets(["username": "alice", key: "x"])
            Issue.record("Expected a violation")
        } catch let violation as MountOptionValidator.Violation {
            #expect(violation.description.contains("\"\(key)\""))
            #expect(!violation.description.contains("x\""))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("validateNoSecrets accepts options without a secret")
    func acceptsOptionsWithoutSecrets() throws {
        try MountOptionValidator.validateNoSecrets([:])
        try MountOptionValidator.validateNoSecrets(["share": "//server/share", "username": "alice", "domain": "CORP", "guest": ""])
    }

    @Test("validateSMBOptions accepts allowlisted SMB keys and gates password on allowPassword")
    func validateSMBAllowlist() throws {
        try MountOptionValidator.validateSMBOptions(
            ["share": "//server/share", "username": "alice", "domain": "CORP", "vers": "3.0", "sec": "ntlmssp", "uid": "1000", "gid": "1000"],
            allowPassword: false
        )
        try MountOptionValidator.validateSMBOptions(
            ["share": "//server/share", "username": "alice", "password": "secret"],
            allowPassword: true
        )
        #expect(throws: MountOptionValidator.Violation.self) {
            try MountOptionValidator.validateSMBOptions(
                ["share": "//server/share", "username": "alice", "password": "secret"],
                allowPassword: false
            )
        }
    }

    @Test(
        "validateSMBOptions rejects non-allowlisted keys including redirects and alternate secret keys",
        arguments: ["ip", "addr", "source", "unc", "pass", "password2", "pass2", "credentials", "cred", "custom_opt"]
    )
    func validateSMBRejectsUnlistedKeys(_ key: String) {
        #expect(throws: MountOptionValidator.Violation.self) {
            try MountOptionValidator.validateSMBOptions(["share": "//server/share", key: "val"], allowPassword: true)
        }
    }

    @Test(
        "validateNFSOptions accepts allowlisted NFS keys and rejects unlisted or secret keys",
        arguments: ["password", "pass", "password2", "pass2", "credentials", "cred", "custom_opt"]
    )
    func validateNFSAllowlist(_ rejectedKey: String) throws {
        try MountOptionValidator.validateNFSOptions([
            "share": "nas.local:/exports/data",
            "addr": "192.168.1.10",
            "vers": "4.1",
            "proto": "tcp",
            "nolock": "",
            "timeo": "600",
        ])
        #expect(throws: MountOptionValidator.Violation.self) {
            try MountOptionValidator.validateNFSOptions(["share": "nas.local:/exports/data", rejectedKey: "val"])
        }
    }

    @Test("validatePerMountOptions accepts only exact ro and rw and never echoes secret values")
    func validatePerMountOptions() throws {
        try MountOptionValidator.validatePerMountOptions([])
        try MountOptionValidator.validatePerMountOptions(["ro"])
        try MountOptionValidator.validatePerMountOptions(["rw"])
        try MountOptionValidator.validatePerMountOptions(["ro", "rw"])

        let rejected = [
            "pass=my-secret",
            "password=my-secret",
            "password2=my-secret",
            "pass2=my-secret",
            "ip=1.2.3.4",
            "addr=1.2.3.4",
            "source=//evil/share",
            "username=other",
            "sec=none",
            "vers=1.0",
            "domain=OTHER",
            "",
            "noatime",
            "RO",
            " ro",
            "ro ",
        ]
        for option in rejected {
            do {
                try MountOptionValidator.validatePerMountOptions([option])
                Issue.record("Expected violation for per-mount option '\(option)'")
            } catch let violation as MountOptionValidator.Violation {
                #expect(!violation.description.contains("my-secret"))
            }
        }
    }
}
