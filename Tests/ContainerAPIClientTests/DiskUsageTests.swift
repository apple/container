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

@testable import ContainerAPIClient

struct DiskUsageTests {

    @Test("DiskUsageStats JSON encoding and decoding")
    func testJSONSerialization() throws {
        let stats = DiskUsageStats(
            images: ResourceUsage(total: 10, active: 5, sizeInBytes: 1024, reclaimable: 512),
            containers: ResourceUsage(total: 3, active: 2, sizeInBytes: 2048, reclaimable: 1024),
            volumes: ResourceUsage(total: 7, active: 4, sizeInBytes: 4096, reclaimable: 2048)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(stats)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DiskUsageStats.self, from: data)

        #expect(decoded.images.total == stats.images.total)
        #expect(decoded.images.active == stats.images.active)
        #expect(decoded.images.sizeInBytes == stats.images.sizeInBytes)
        #expect(decoded.images.reclaimable == stats.images.reclaimable)

        #expect(decoded.containers.total == stats.containers.total)
        #expect(decoded.containers.active == stats.containers.active)
        #expect(decoded.containers.sizeInBytes == stats.containers.sizeInBytes)
        #expect(decoded.containers.reclaimable == stats.containers.reclaimable)

        #expect(decoded.volumes.total == stats.volumes.total)
        #expect(decoded.volumes.active == stats.volumes.active)
        #expect(decoded.volumes.sizeInBytes == stats.volumes.sizeInBytes)
        #expect(decoded.volumes.reclaimable == stats.volumes.reclaimable)
    }

    @Test("ResourceUsage with zero values")
    func testZeroValues() throws {
        let emptyUsage = ResourceUsage(total: 0, active: 0, sizeInBytes: 0, reclaimable: 0)

        let encoder = JSONEncoder()
        let data = try encoder.encode(emptyUsage)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ResourceUsage.self, from: data)

        #expect(decoded.total == 0)
        #expect(decoded.active == 0)
        #expect(decoded.sizeInBytes == 0)
        #expect(decoded.reclaimable == 0)
    }

    @Test("ResourceUsage with large values")
    func testLargeValues() throws {
        let largeUsage = ResourceUsage(
            total: 1000,
            active: 500,
            sizeInBytes: UInt64.max,
            reclaimable: UInt64.max / 2
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(largeUsage)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ResourceUsage.self, from: data)

        #expect(decoded.total == 1000)
        #expect(decoded.active == 500)
        #expect(decoded.sizeInBytes == UInt64.max)
        #expect(decoded.reclaimable == UInt64.max / 2)
    }

    @Test("ResourceUsage percentage calculations")
    func testPercentageCalculations() throws {
        // 0% reclaimable
        let noneReclaimable = ResourceUsage(total: 10, active: 10, sizeInBytes: 1000, reclaimable: 0)
        #expect(Double(noneReclaimable.reclaimable) / Double(noneReclaimable.sizeInBytes) == 0.0)

        // 50% reclaimable
        let halfReclaimable = ResourceUsage(total: 10, active: 5, sizeInBytes: 1000, reclaimable: 500)
        #expect(Double(halfReclaimable.reclaimable) / Double(halfReclaimable.sizeInBytes) == 0.5)

        // 100% reclaimable
        let allReclaimable = ResourceUsage(total: 10, active: 0, sizeInBytes: 1000, reclaimable: 1000)
        #expect(Double(allReclaimable.reclaimable) / Double(allReclaimable.sizeInBytes) == 1.0)
    }
}
