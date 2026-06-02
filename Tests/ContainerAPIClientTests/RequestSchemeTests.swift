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
import Testing

@testable import ContainerAPIClient

struct RequestSchemeTests {
    static let defaultDnsDomain = "test"

    internal struct TestArg {
        let scheme: String
        let host: String
        let expected: RequestScheme
    }

    @Test(arguments: [
        TestArg(scheme: "http", host: "myregistry.io", expected: .http),
        TestArg(scheme: "https", host: "myregistry.io", expected: .https),
        TestArg(scheme: "auto", host: "myregistry.io", expected: .https),
        TestArg(scheme: "https", host: "localhost", expected: .https),
        TestArg(scheme: "http", host: "localhost", expected: .http),
        TestArg(scheme: "auto", host: "localhost", expected: .http),
        TestArg(scheme: "auto", host: "localhost.evil.com", expected: .https),
        TestArg(scheme: "http", host: "127.0.0.1", expected: .http),
        TestArg(scheme: "https", host: "127.0.0.1", expected: .https),
        TestArg(scheme: "auto", host: "127.0.0.1", expected: .http),
        TestArg(scheme: "auto", host: "127.255.255.255", expected: .http),
        TestArg(scheme: "auto", host: "127.0.0.1.evil.com", expected: .https),
        TestArg(scheme: "https", host: "10.3.4.1", expected: .https),
        TestArg(scheme: "auto", host: "10.3.4.1", expected: .http),
        TestArg(scheme: "auto", host: "10.255.255.255", expected: .http),
        TestArg(scheme: "auto", host: "10.0.0.1.evil.com", expected: .https),
        TestArg(scheme: "auto", host: "192.168.0.1", expected: .http),
        TestArg(scheme: "auto", host: "192.168.255.255", expected: .http),
        TestArg(scheme: "auto", host: "192.169.0.1", expected: .https),
        TestArg(scheme: "auto", host: "192.168.1.1.evil.com", expected: .https),
        TestArg(scheme: "auto", host: "some-dns-name.io", expected: .https),
        TestArg(scheme: "auto", host: "172.32.0.1", expected: .https),
        TestArg(scheme: "auto", host: "172.22.23.61", expected: .http),
        TestArg(scheme: "auto", host: "172.16.0.0", expected: .http),
        TestArg(scheme: "auto", host: "172.31.255.255", expected: .http),
    ])

    func testIsConnectionSecure(arg: TestArg) throws {
        let requestScheme = RequestScheme(rawValue: arg.scheme)!
        #expect(try requestScheme.schemeFor(host: arg.host, internalDnsDomain: Self.defaultDnsDomain) == arg.expected)
    }

    @Test func testEmptyHostThrowsError() throws {
        #expect(throws: (any Error).self) {
            let requestScheme = RequestScheme(rawValue: "https")!
            _ = try requestScheme.schemeFor(host: "", internalDnsDomain: Self.defaultDnsDomain)
        }
    }

    @Test func testIsInternalHostWithDefaultDNSDomain() throws {
        let hostName = "some-dns-name.io.\(Self.defaultDnsDomain)"
        #expect(RequestScheme.isInternalHost(host: hostName, internalDnsDomain: Self.defaultDnsDomain))
    }
}
