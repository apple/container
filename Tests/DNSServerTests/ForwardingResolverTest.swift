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

@testable import DNSServer

struct ForwardingResolverTest {
    @Test func testSystemUpstreamsParsesNameservers() throws {
        let resolvConf = try temporaryFile(contents: """
            # comment
            nameserver 127.0.0.1
            nameserver 127.0.0.53
            nameserver localhost
            nameserver 192.0.2.53
            nameserver 2001:db8::53
            search example.com
            """)
        defer { try? FileManager.default.removeItem(at: resolvConf) }

        let upstreams = ForwardingResolver.systemUpstreams(resolvConfPath: resolvConf.path)

        #expect([
            ForwardingResolver.Upstream(host: "192.0.2.53"),
            ForwardingResolver.Upstream(host: "2001:db8::53"),
        ] == upstreams)
    }

    @Test func testSystemUpstreamsFallsBackWhenNoUsableNameservers() throws {
        let resolvConf = try temporaryFile(contents: """
            nameserver 127.0.0.1
            nameserver 127.0.0.53
            nameserver ::1
            nameserver 0.0.0.0
            nameserver ::
            nameserver not-an-ip
            """)
        defer { try? FileManager.default.removeItem(at: resolvConf) }

        let upstreams = ForwardingResolver.systemUpstreams(resolvConfPath: resolvConf.path)

        #expect([ForwardingResolver.Upstream(host: "1.1.1.1")] == upstreams)
    }

    private func temporaryFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-dns-forwarding-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
