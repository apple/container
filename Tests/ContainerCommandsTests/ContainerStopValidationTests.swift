//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

import ContainerClient
import ContainerCommands
import ContainerizationError
import Testing

@testable import ContainerCommands

struct ContainerStopValidationTests {
    struct StubContainer: ContainerIdentifiable {
        let id: String
        let status: RuntimeStatus
    }

    @Test
    func resolvesExactIds() throws {
        let containers = [StubContainer(id: "abc123", status: .running)]
        let matched = try Application.ContainerStop.containers(matching: ["abc123"], in: containers)
        #expect(matched.count == 1)
        #expect(matched.first?.id == "abc123")
    }

    @Test
    func resolvesIdPrefixes() throws {
        let containers = [
            StubContainer(id: "abcdef", status: .running),
            StubContainer(id: "123456", status: .running),
        ]
        let matched = try Application.ContainerStop.containers(matching: ["abc"], in: containers)
        #expect(matched.count == 1)
        #expect(matched.first?.id == "abcdef")
    }

    @Test
    func prefersExactIdOverPrefixMatches() throws {
        let containers = [
            StubContainer(id: "abc", status: .running),
            StubContainer(id: "abcdef", status: .running),
        ]
        let matched = try Application.ContainerStop.containers(matching: ["abc"], in: containers)
        #expect(matched.count == 1)
        #expect(matched.first?.id == "abc")
    }

    @Test
    func throwsForAmbiguousPrefixes() throws {
        let containers = [
            StubContainer(id: "abc123", status: .running),
            StubContainer(id: "abcd99", status: .running),
        ]
        #expect {
            _ = try Application.ContainerStop.containers(matching: ["abc"], in: containers)
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.code == .invalidArgument
        }
    }

    @Test
    func throwsForMissingContainers() throws {
        let containers = [StubContainer(id: "abcdef", status: .running)]
        #expect {
            _ = try Application.ContainerStop.containers(matching: ["missing"], in: containers)
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.code == .notFound
        }
    }
}
