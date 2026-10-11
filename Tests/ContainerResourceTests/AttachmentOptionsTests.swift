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

struct AttachmentOptionsTests {
    @Test(
        "canonicalHostname lowercases and removes a trailing dot",
        arguments: [
            ("foo.test.", "foo.test"),
            ("foo.test", "foo.test"),
            ("Foo.Test.", "foo.test"),
            ("FOO", "foo"),
            ("foo", "foo"),
            ("", ""),
        ])
    func canonicalHostname(input: String, expected: String) {
        #expect(AttachmentOptions.canonicalHostname(input) == expected)
    }

    @Test("Options encoded before aliases existed decode with no aliases")
    func decodeWithoutAliases() throws {
        let json = #"{"hostname":"foo.test.","mtu":1280}"#
        let options = try JSONDecoder().decode(AttachmentOptions.self, from: Data(json.utf8))
        #expect(options.hostname == "foo.test.")
        #expect(options.mtu == 1280)
        #expect(options.aliases == nil)
    }

    @Test("Options without aliases do not encode an aliases key")
    func encodeWithoutAliases() throws {
        let data = try JSONEncoder().encode(AttachmentOptions(hostname: "foo.test."))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("aliases"))
    }

    @Test("Aliases round trip through JSON")
    func aliasesRoundTrip() throws {
        let aliases = ["api.example.test", ".example.test"]
        let original = AttachmentOptions(hostname: "foo.test.", mtu: 1500, aliases: aliases)
        let decoded = try JSONDecoder().decode(AttachmentOptions.self, from: JSONEncoder().encode(original))
        #expect(decoded.hostname == original.hostname)
        #expect(decoded.mtu == original.mtu)
        #expect(decoded.aliases == aliases)
    }

    @Test("Aliases round trip inside an attachment configuration")
    func aliasesRoundTripInConfiguration() throws {
        let original = AttachmentConfiguration(
            network: "default",
            options: AttachmentOptions(hostname: "foo.test.", aliases: [".foo.test"])
        )
        let decoded = try JSONDecoder().decode(AttachmentConfiguration.self, from: JSONEncoder().encode(original))
        #expect(decoded.network == "default")
        #expect(decoded.options.aliases == [".foo.test"])
    }
}
