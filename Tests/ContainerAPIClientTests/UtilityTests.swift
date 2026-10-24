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

struct UtilityTests {

    @Test("Parse simple key-value pairs")
    func testSimpleKeyValuePairs() {
        let result = Utility.parseKeyValuePairs(["key1=value1", "key2=value2"])

        #expect(result["key1"] == "value1")
        #expect(result["key2"] == "value2")
    }

    @Test("Parse standalone keys")
    func testStandaloneKeys() {
        let result = Utility.parseKeyValuePairs(["standalone"])

        #expect(result["standalone"] == "")
    }

    @Test("Parse empty input")
    func testEmptyInput() {
        let result = Utility.parseKeyValuePairs([])

        #expect(result.isEmpty)
    }

    @Test("Parse mixed format")
    func testMixedFormat() {
        let result = Utility.parseKeyValuePairs(["key1=value1", "standalone", "key2=value2"])

        #expect(result["key1"] == "value1")
        #expect(result["standalone"] == "")
        #expect(result["key2"] == "value2")
    }

    @Test("Valid MAC address with colons")
    func testValidMACAddressWithColons() throws {
        try Utility.validMACAddress("02:42:ac:11:00:02")
        try Utility.validMACAddress("AA:BB:CC:DD:EE:FF")
        try Utility.validMACAddress("00:00:00:00:00:00")
        try Utility.validMACAddress("ff:ff:ff:ff:ff:ff")
    }

    @Test("Valid MAC address with hyphens")
    func testValidMACAddressWithHyphens() throws {
        try Utility.validMACAddress("02-42-ac-11-00-02")
        try Utility.validMACAddress("AA-BB-CC-DD-EE-FF")
    }

    @Test("Invalid MAC address format")
    func testInvalidMACAddressFormat() {
        #expect(throws: Error.self) {
            try Utility.validMACAddress("invalid")
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00")  // Too short
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00:02:03")  // Too long
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("ZZ:ZZ:ZZ:ZZ:ZZ:ZZ")  // Invalid hex
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00:")  // Incomplete
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02.42.ac.11.00.02")  // Wrong separator
        }
    }

    @Test("Trim fully-qualified digest strips scheme and truncates to 12 chars")
    func testTrimDigestFullyQualified() {
        let hex = "0be69a25c33692845efb1e93f4254f28505a330896376bf8"
        #expect(Utility.trimDigest(digest: "sha256:\(hex)") == String(hex.prefix(12)))
    }

    @Test("Trim digest with unknown scheme strips scheme prefix")
    func testTrimDigestUnknownScheme() {
        let hex = "abcdef123456789012345678"
        #expect(Utility.trimDigest(digest: "blake3:\(hex)") == String(hex.prefix(12)))
    }

    @Test("Trim digest with no scheme truncates directly")
    func testTrimDigestNoScheme() {
        let hex = "abcdef1234567890"
        #expect(Utility.trimDigest(digest: hex) == String(hex.prefix(12)))
    }

    @Test("Trim digest shorter than 12 chars returns value unchanged")
    func testTrimDigestShort() {
        #expect(Utility.trimDigest(digest: "sha256:abc") == "abc")
    }

    @Test
    func testPublishPortParser() throws {
        let ports = try Parser.publishPorts([
            "127.0.0.1:8000:9080",
            "8080-8179:9000-9099/udp",
        ])
        #expect(ports.count == 2)
        #expect(ports[0].hostAddress.description == "127.0.0.1")
        #expect(ports[0].hostPort == 8000)
        #expect(ports[0].containerPort == 9080)
        #expect(ports[0].proto == .tcp)
        #expect(ports[0].count == 1)
        #expect(ports[1].hostAddress.description == "0.0.0.0")
        #expect(ports[1].hostPort == 8080)
        #expect(ports[1].containerPort == 9000)
        #expect(ports[1].proto == .udp)
        #expect(ports[1].count == 100)
    }

    @Test("Aliases from the network specification land on the attachment they were declared for")
    func testAttachmentConfigurationsCarryAliases() throws {
        let networks = [
            Parser.ParsedNetwork(name: "default", aliases: ["api.test", ".foo.test"]),
            Parser.ParsedNetwork(name: "backend"),
        ]

        let attachments = try Utility.getAttachmentConfigurations(
            containerId: "foo",
            builtinNetworkId: "default",
            networks: networks,
            dnsDomain: "test"
        )

        #expect(attachments.count == 2)
        #expect(attachments[0].network == "default")
        #expect(attachments[0].options.hostname == "foo.test.")
        #expect(attachments[0].options.aliases == ["api.test", ".foo.test"])
        #expect(attachments[1].network == "backend")
        #expect(attachments[1].options.hostname == "foo")
        #expect(attachments[1].options.aliases.isEmpty)
    }

    @Test("Aliases are carried to a later attachment")
    func testAttachmentConfigurationsCarryAliasesOnLaterNetworks() throws {
        let networks = [
            Parser.ParsedNetwork(name: "default"),
            Parser.ParsedNetwork(name: "backend", aliases: ["db.internal"]),
        ]

        let attachments = try Utility.getAttachmentConfigurations(
            containerId: "foo",
            builtinNetworkId: "default",
            networks: networks,
            dnsDomain: "test"
        )

        #expect(attachments[0].options.aliases.isEmpty)
        #expect(attachments[1].options.aliases == ["db.internal"])
    }

    @Test("A container with no network specification has no aliases")
    func testDefaultAttachmentHasNoAliases() throws {
        let attachments = try Utility.getAttachmentConfigurations(
            containerId: "foo",
            builtinNetworkId: "default",
            networks: [],
            dnsDomain: "test"
        )

        #expect(attachments.count == 1)
        #expect(attachments[0].options.aliases.isEmpty)
    }

    @Test("Aliases without a domain get the default domain")
    func testQualifyAliasesAddsTheDefaultDomain() throws {
        let aliases = try Utility.qualifyAliases(["api", ".gateway"], dnsDomain: "test")

        #expect(aliases == ["api.test", ".gateway.test"])
    }

    @Test("Aliases with a dot are taken to be qualified")
    func testQualifyAliasesLeavesQualifiedNamesAlone() throws {
        let aliases = try Utility.qualifyAliases(["web.internal", ".a.b", "api.test"], dnsDomain: "test")

        #expect(aliases == ["web.internal", ".a.b", "api.test"])
    }

    @Test("Aliases are left as they are without a default domain")
    func testQualifyAliasesWithoutADefaultDomain() throws {
        let aliases = try Utility.qualifyAliases(["api", ".gateway", "web.internal"], dnsDomain: nil)

        #expect(aliases == ["api", ".gateway", "web.internal"])
    }

    @Test("No aliases stay empty")
    func testQualifyAliasesWithNoAliases() throws {
        #expect(try Utility.qualifyAliases([], dnsDomain: "test").isEmpty)
        #expect(try Utility.qualifyAliases([], dnsDomain: nil).isEmpty)
    }

    @Test("The default domain is normalized when it is added")
    func testQualifyAliasesNormalizesTheDomain() throws {
        let aliases = try Utility.qualifyAliases(["api", ".gateway"], dnsDomain: "Example.TEST.")

        #expect(aliases == ["api.example.test", ".gateway.example.test"])
    }

    @Test("A default domain that is not a valid name is reported")
    func testQualifyAliasesWithAnInvalidDomain() {
        #expect(throws: (any Error).self) {
            try Utility.qualifyAliases(["api"], dnsDomain: "not a domain")
        }
    }

    @Test("Aliases in a network specification are qualified when the attachments are built")
    func testAttachmentConfigurationsQualifyAliases() throws {
        let networks = [
            Parser.ParsedNetwork(name: "default", aliases: ["api", ".foo"]),
            Parser.ParsedNetwork(name: "backend", aliases: ["db"]),
        ]

        let attachments = try Utility.getAttachmentConfigurations(
            containerId: "foo",
            builtinNetworkId: "default",
            networks: networks,
            dnsDomain: "test"
        )

        #expect(attachments[0].options.hostname == "foo.test.")
        #expect(attachments[0].options.aliases == ["api.test", ".foo.test"])
        #expect(attachments[1].options.aliases == ["db.test"])
    }

    @Test("Infra images are recognized at the configured reference exactly")
    func testInfraImageExactMatch() {
        #expect(
            Utility.isInfraImage(
                name: "ghcr.io/apple/containerization/vminit:1.0.0",
                builderImage: "ghcr.io/apple/container-builder-shim/builder:0.5.0",
                initImage: "ghcr.io/apple/containerization/vminit:1.0.0"))
    }

    @Test("Infra images are recognized at other tags of the configured repository")
    func testInfraImageOtherTag() {
        // The copy left behind by a previous release: same repository, older tag.
        #expect(
            Utility.isInfraImage(
                name: "ghcr.io/apple/containerization/vminit:0.9.0",
                builderImage: "ghcr.io/apple/container-builder-shim/builder:0.5.0",
                initImage: "ghcr.io/apple/containerization/vminit:1.0.0"))
    }

    @Test("Infra images are recognized by digest reference")
    func testInfraImageDigestReference() {
        #expect(
            Utility.isInfraImage(
                name: "ghcr.io/apple/containerization/vminit@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                builderImage: "ghcr.io/apple/container-builder-shim/builder:0.5.0",
                initImage: "ghcr.io/apple/containerization/vminit:1.0.0"))
    }

    @Test("A registry port is not mistaken for a tag")
    func testInfraImageRegistryPort() {
        // The tag colon is the one after the last path separator; a bare colon
        // in the registry host must not truncate the reference at the port.
        #expect(
            Utility.isInfraImage(
                name: "registry.local:5000/infra/vminit:2.0.0",
                builderImage: "registry.local:5000/infra/vminit:1.0.0",
                initImage: "ghcr.io/apple/containerization/vminit:1.0.0"))
        #expect(
            !Utility.isInfraImage(
                name: "registry.local:5000/infra/other:1.0.0",
                builderImage: "registry.local:5000/infra/vminit:1.0.0",
                initImage: "ghcr.io/apple/containerization/vminit:1.0.0"))
    }

    @Test("User images sharing only a name suffix are not infra")
    func testUserImageNotInfra() {
        #expect(
            !Utility.isInfraImage(
                name: "docker.io/library/vminit:1.0.0",
                builderImage: "ghcr.io/apple/container-builder-shim/builder:0.5.0",
                initImage: "ghcr.io/apple/containerization/vminit:1.0.0"))
        #expect(
            !Utility.isInfraImage(
                name: "docker.io/library/nginx:alpine",
                builderImage: "ghcr.io/apple/container-builder-shim/builder:0.5.0",
                initImage: "ghcr.io/apple/containerization/vminit:1.0.0"))
    }
}
