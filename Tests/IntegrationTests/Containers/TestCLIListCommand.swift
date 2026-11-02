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

import ContainerAPIClient
import ContainerResource
import ContainerTestSupport
import Foundation
import Testing

@Suite
struct TestCLIListCommand {
    @Test func testListFilterServerSideAnchoredRegex() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            let c1 = "\(f.testID)-c1"
            let c2 = "\(f.testID)-c2"
            let c3 = "\(f.testID)-c3"
            let c4 = "\(f.testID)-c4"

            try f.run([
                "create", "--name", c1,
                "--label", "test-id=\(f.testID)",
                "--label", "version=1.0.0",
                "--label", "env=prod",
                image,
            ]).check()
            f.addCleanup { _ = try? f.run(["delete", "--force", c1]) }

            try f.run([
                "create", "--name", c2,
                "--label", "test-id=\(f.testID)",
                "--label", "version=1.0.0.1",
                "--label", "env=prod",
                image,
            ]).check()
            f.addCleanup { _ = try? f.run(["delete", "--force", c2]) }

            try f.run([
                "create", "--name", c3,
                "--label", "test-id=\(f.testID)",
                "--label", "version=1a0b0",
                "--label", "env=stage",
                image,
            ]).check()
            f.addCleanup { _ = try? f.run(["delete", "--force", c3]) }

            try f.run([
                "create", "--name", c4,
                "--label", "test-id=\(f.testID)",
                "--label", "release=v1.0+alpha.1",
                image,
            ]).check()
            f.addCleanup { _ = try? f.run(["delete", "--force", c4]) }

            let client = ContainerClient()

            // 1. Verify server-side filtering via client.list directly using anchored regex.
            //    The anchored pattern "^1\.0\.0$" must match c1 ("1.0.0"),
            //    and must NOT match c2 ("1.0.0.1" unanchored prefix) or c3 ("1a0b0" unescaped dot).
            let versionPattern = "^\(NSRegularExpression.escapedPattern(for: "1.0.0"))$"
            let versionFiltered = try await client.list(
                filters: ContainerListFilters(
                    labels: [
                        "test-id": "^\(NSRegularExpression.escapedPattern(for: f.testID))$",
                        "version": versionPattern,
                    ]
                ).withoutMachines()
            )
            let versionIDs = versionFiltered.map(\.id)
            #expect(versionIDs == [c1], "server-side anchored filter should only match exact version 1.0.0")

            // 2. Verify server-side filtering with regex special characters (e.g. '+').
            let specialPattern = "^\(NSRegularExpression.escapedPattern(for: "v1.0+alpha.1"))$"
            let specialFiltered = try await client.list(
                filters: ContainerListFilters(
                    labels: [
                        "test-id": "^\(NSRegularExpression.escapedPattern(for: f.testID))$",
                        "release": specialPattern,
                    ]
                ).withoutMachines()
            )
            let specialIDs = specialFiltered.map(\.id)
            #expect(specialIDs == [c4], "server-side filter should match literal regex-special characters")

            // 3. Verify CLI container ls / list --filter label=key=value
            let cliVersionResult = try f.run([
                "ls", "-a", "-q",
                "-f", "label=test-id=\(f.testID)",
                "-f", "label=version=1.0.0",
            ]).check()
            let cliVersionIDs = cliVersionResult.output.split(separator: "\n").map(String.init)
            #expect(cliVersionIDs == [c1], "CLI --filter should output only exact label match")

            let cliSpecialResult = try f.run([
                "list", "-a", "-q",
                "--filter", "label=test-id=\(f.testID)",
                "--filter", "label=release=v1.0+alpha.1",
            ]).check()
            let cliSpecialIDs = cliSpecialResult.output.split(separator: "\n").map(String.init)
            #expect(cliSpecialIDs == [c4], "CLI --filter should match special characters")

            // 4. Verify CLI container ls with label presence filter
            let cliPresenceResult = try f.run([
                "ls", "-a", "-q",
                "-f", "label=test-id=\(f.testID)",
                "-f", "label=version",
            ]).check()
            let cliPresenceIDs = Set(cliPresenceResult.output.split(separator: "\n").map(String.init))
            #expect(cliPresenceIDs == Set([c1, c2, c3]), "CLI label presence filter should return all containers with the key")
        }
    }
}
