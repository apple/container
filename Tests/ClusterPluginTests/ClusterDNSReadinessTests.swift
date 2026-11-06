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

import Testing

@testable import ContainerCluster

@Suite("ClusterHelper.apiEndpointIsCurrent")
struct ClusterDNSReadinessTests {
    @Test func singleMatchingAddressIsCurrent() {
        #expect(ClusterHelper.apiEndpointIsCurrent(addresses: "192.168.64.5", controlPlaneAddress: "192.168.64.5"))
    }

    @Test func oldAndNewAddressListedIsNotCurrent() {
        #expect(!ClusterHelper.apiEndpointIsCurrent(addresses: "192.168.64.4 192.168.64.5", controlPlaneAddress: "192.168.64.5"))
    }

    @Test func singleDifferentAddressIsNotCurrent() {
        #expect(!ClusterHelper.apiEndpointIsCurrent(addresses: "192.168.64.4", controlPlaneAddress: "192.168.64.5"))
    }

    @Test func emptyOutputIsNotCurrent() {
        #expect(!ClusterHelper.apiEndpointIsCurrent(addresses: "", controlPlaneAddress: "192.168.64.5"))
    }

    @Test func surroundingWhitespaceIsIgnored() {
        #expect(ClusterHelper.apiEndpointIsCurrent(addresses: "  192.168.64.5\n", controlPlaneAddress: "192.168.64.5"))
    }
}
