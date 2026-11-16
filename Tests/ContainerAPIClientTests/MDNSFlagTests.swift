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
import Testing

@testable import ContainerAPIClient

struct MDNSFlagTests {
    @Test
    func mdnsIsOffByDefault() throws {
        let flags = try Flags.Management.parse([])
        #expect(!flags.mdns)
    }

    @Test
    func parsesTheMDNSFlag() throws {
        let flags = try Flags.Management.parse(["--mdns", "--publish", "51826:51826"])
        #expect(flags.mdns)
        #expect(flags.publishPorts == ["51826:51826"])
    }

    @Test
    func mdnsWithAPublishedPortIsValid() throws {
        let ports = try Parser.publishPorts(["51826:51826"])
        try Utility.validateMDNS(enabled: true, publishedPorts: ports)
    }

    @Test
    func mdnsWithoutAPublishedPortIsRejected() throws {
        let error = try #require(throws: ContainerizationError.self) {
            try Utility.validateMDNS(enabled: true, publishedPorts: [])
        }
        #expect(error.code == .invalidArgument)
        #expect(error.message.contains("--publish"))
    }

    @Test
    func noPublishedPortIsFineWithoutMDNS() throws {
        try Utility.validateMDNS(enabled: false, publishedPorts: [])
    }
}
