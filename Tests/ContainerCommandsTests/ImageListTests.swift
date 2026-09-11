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

@testable import ContainerCommands

struct ImageListTests {
    private enum TestError: Error {
        case unreadable
    }

    @Test
    func unreadableEntryDoesNotPreventOtherEntriesFromResolving() async {
        let inputs = ["healthy-one", "unreadable", "healthy-two"]
        var failures: [String] = []
        var failureDescriptions: [String] = []

        let values = await Application.ImageList.collectReadableValues(
            from: inputs,
            resolve: { input in
                if input == "unreadable" {
                    throw TestError.unreadable
                }
                return input.uppercased()
            },
            onError: { input, error in
                failures.append(input)
                failureDescriptions.append("\(error)")
            }
        )

        #expect(values == ["HEALTHY-ONE", "HEALTHY-TWO"])
        #expect(failures == ["unreadable"])
        #expect(failureDescriptions == ["unreadable"])
    }
}
