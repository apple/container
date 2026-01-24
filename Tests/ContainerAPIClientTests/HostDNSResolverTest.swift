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

import ContainerizationError
import ContainerizationExtras
import Foundation
import Testing

@testable import ContainerAPIClient

struct HostDNSResolverTest {
    @Test
    func testHostDNSCreate() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let resolver = HostDNSResolver(configURL: tempURL)
        try resolver.createDomain(name: "foo.bar")
        let resolverConfigURL = tempURL.appending(path: "containerization.foo.bar")
        let actualText = try String(contentsOf: resolverConfigURL, encoding: .utf8)
        let expectedText = """
            domain foo.bar
            search foo.bar
            nameserver 127.0.0.1
            port 2053

            """

        #expect(actualText == expectedText)

        try resolver.createDomain(name: "bar.foo")
        let domains = resolver.listDomains()
        #expect(domains == ["bar.foo", "foo.bar"])
    }

    @Test
    func testHostDNSCreateAlreadyExists() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let resolver = HostDNSResolver(configURL: tempURL)
        try resolver.createDomain(name: "foo.bar")
        #expect {
            try resolver.createDomain(name: "foo.bar")
        } throws: { error in
            guard let error = error as? ContainerizationError, error.code == .exists else {
                return false
            }
            return true
        }
    }

    @Test
    func testHostDNSDelete() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let resolver = HostDNSResolver(configURL: tempURL)
        try resolver.createDomain(name: "foo.bar")
        _ = try resolver.deleteDomain(name: "foo.bar")

        let localhost = try! IPAddress("127.0.0.1")
        try resolver.createDomain(name: "bar.baz", localhost: localhost)
        let deletedLocalhost = try resolver.deleteDomain(name: "bar.baz")
        #expect(localhost == deletedLocalhost)

        let domains = resolver.listDomains()
        #expect(domains == [])
    }

    @Test
    func testHostDNSDeleteNotFound() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let resolver = HostDNSResolver(configURL: tempURL)
        try resolver.createDomain(name: "foo.bar")
        #expect {
            _ = try resolver.deleteDomain(name: "bar.foo")
        } throws: { error in
            guard let error = error as? ContainerizationError, error.code == .notFound else {
                return false
            }
            return true
        }
    }

    @Test
    func testHostDNSReinitialize() async throws {
        let isAdmin = getuid() == 0
        do {
            try HostDNSResolver.reinitialize()
            #expect(isAdmin)
        } catch {
            let containerizationError = try #require(error as? ContainerizationError)
            #expect(containerizationError.code == .internalError)
            #expect(containerizationError.message == "mDNSResponder restart failed with status 1")
            #expect(!isAdmin)
        }
    }
}
