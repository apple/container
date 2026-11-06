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

@testable import ContainerCluster

@Suite("ClusterHelper.leaseRenewedAfter")
struct ClusterNodeLeaseTests {
    private let since = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func leaseRenewedAfterStartIsFresh() {
        let renewTime = ISO8601DateFormatter().string(from: since.addingTimeInterval(10))

        #expect(ClusterHelper.leaseRenewedAfter(renewTime: renewTime, since: since))
    }

    @Test func leaseRenewedBeforeStartIsStale() {
        let renewTime = ISO8601DateFormatter().string(from: since.addingTimeInterval(-10))

        #expect(!ClusterHelper.leaseRenewedAfter(renewTime: renewTime, since: since))
    }

    @Test func leaseWithFractionalSecondsIsParsed() {
        #expect(ClusterHelper.leaseRenewedAfter(renewTime: "2027-01-15T08:00:10.123456Z", since: since))
    }

    @Test func unparsableLeaseIsStale() {
        #expect(!ClusterHelper.leaseRenewedAfter(renewTime: "", since: since))
    }
}
