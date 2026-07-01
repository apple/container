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

@testable import ContainerCommands

struct MachineSetArgumentsTests {
    // MARK: pairs

    @Test func pairsSplitsKeyValue() throws {
        let pairs = try MachineSetArguments.pairs(["cpus=4", "memory=2G"])
        #expect(pairs.count == 2)
        #expect(pairs[0].key == "cpus")
        #expect(pairs[0].value == "4")
        #expect(pairs[1].key == "memory")
        #expect(pairs[1].value == "2G")
    }

    @Test func pairsKeepsEqualsInValue() throws {
        // Only the first `=` separates key from value, so the value may
        // itself contain `=` (e.g. `console=ttyS0`).
        let pairs = try MachineSetArguments.pairs(["kernel-arg=console=ttyS0"])
        #expect(pairs[0].key == "kernel-arg")
        #expect(pairs[0].value == "console=ttyS0")
    }

    @Test func pairsAllowsEmptyValue() throws {
        let pairs = try MachineSetArguments.pairs(["network="])
        #expect(pairs[0].key == "network")
        #expect(pairs[0].value == "")
    }

    @Test func pairsRejectsMissingEquals() {
        #expect(throws: ContainerizationError.self) {
            _ = try MachineSetArguments.pairs(["cpus"])
        }
    }

    // MARK: list

    @Test func listReturnsNilWhenKeyAbsent() throws {
        let pairs = try MachineSetArguments.pairs(["cpus=4"])
        #expect(MachineSetArguments.list(forKey: "network", in: pairs) == nil)
    }

    @Test func listCollectsRepeatedValuesInOrder() throws {
        let pairs = try MachineSetArguments.pairs(["network=default", "network=lan,ip=1.2.3.4"])
        #expect(MachineSetArguments.list(forKey: "network", in: pairs) == ["default", "lan,ip=1.2.3.4"])
    }

    @Test func listEmptyValueResetsToEmptyArray() throws {
        let pairs = try MachineSetArguments.pairs(["network="])
        #expect(MachineSetArguments.list(forKey: "network", in: pairs) == [])
    }

    @Test func listDropsEmptyAmongNonEmpty() throws {
        let pairs = try MachineSetArguments.pairs(["network=", "network=lan"])
        #expect(MachineSetArguments.list(forKey: "network", in: pairs) == ["lan"])
    }

    // MARK: scalars

    @Test func scalarsExcludesListKeysAndDedups() throws {
        let pairs = try MachineSetArguments.pairs([
            "cpus=2", "network=lan", "kernel-arg=quiet", "cpus=4",
        ])
        let scalars = MachineSetArguments.scalars(pairs, excluding: ["network", "kernel-arg"])
        // List keys removed; the later cpus wins.
        #expect(scalars == ["cpus": "4"])
    }
}
