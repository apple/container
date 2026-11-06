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
import Foundation
import Testing

@testable import ContainerCommands

struct SystemStopValidationTests {
    @Test
    func rejectsPathPrefix() {
        #expect {
            try Self.parseAndValidate(["--prefix", "/usr/local/container"])
        } throws: { error in
            String(describing: error).contains("invalid --prefix \"/usr/local/container\"")
        }
    }

    @Test
    func rejectsInvalidCharacters() {
        #expect {
            try Self.parseAndValidate(["--prefix", "foo bar"])
        } throws: { error in
            String(describing: error).contains("invalid --prefix \"foo bar\"")
        }
    }

    @Test
    func acceptsDefaultPrefix() throws {
        try Self.parseAndValidate([])
    }

    @Test
    func acceptsCustomReverseDNSPrefix() throws {
        try Self.parseAndValidate(["--prefix", "com.example.svc."])
    }

    private static func parseAndValidate(_ args: [String]) throws {
        var command = try Application.SystemStop.parse(args)
        try command.validate()
    }
}
