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

import ArgumentParser
import ContainerResource
import Foundation
import Testing

@testable import ContainerCommands

struct ContainerCreateTests {
    @Test func acceptsJSONOutputFormat() throws {
        let command = try Application.ContainerCreate.parse([
            "--format", "json", "docker.io/library/alpine:latest",
        ])

        #expect(command.format == .json)
    }

    @Test func createResultRendersAsMachineReadableJSON() throws {
        let expected = ContainerCreateResult(id: "created", instanceToken: "server-token")
        let rendered = try Output.renderJSON(expected)
        let decoded = try JSONDecoder().decode(ContainerCreateResult.self, from: Data(rendered.utf8))

        #expect(decoded == expected)
    }
}
