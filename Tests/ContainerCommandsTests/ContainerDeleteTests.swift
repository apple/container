//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ArgumentParser
import Testing

@testable import ContainerCommands

struct ContainerDeleteTests {
    @Test func instanceTokenRequiresOneExplicitContainer() throws {
        #expect(throws: (any Error).self) {
            _ = try Application.ContainerDelete.parse([
                "--if-instance-token", "opaque-token", "--all",
            ])
        }

        #expect(throws: (any Error).self) {
            _ = try Application.ContainerDelete.parse([
                "--if-instance-token", "opaque-token", "first", "second",
            ])
        }
    }

    @Test func instanceTokenAcceptsOneExplicitContainer() throws {
        let command = try Application.ContainerDelete.parse([
            "--force", "--if-instance-token", "opaque-token", "target",
        ])

        try command.validate()
        #expect(command.force)
        #expect(command.ifInstanceToken == "opaque-token")
        #expect(command.containerIds == ["target"])
    }
}
