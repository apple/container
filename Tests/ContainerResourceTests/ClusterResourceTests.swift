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

@testable import ContainerResource

struct ClusterResourceTests {
    @Test func nameValidAcceptsSafePathComponents() {
        for good in ["a", "dev", "cluster-dev", "my_cluster", "v1.35", "0abc", String(repeating: "a", count: 63)] {
            #expect(ClusterResource.nameValid(good), "\(good) should be valid")
        }
    }

    @Test func nameValidRejectsUnsafeNames() {
        let bad = [
            "", ".", "..", ".hidden", "-dash", "_under", "a/b", "../x", "a\\b", "dev\n", "dev ", "dév", "a\u{0}b",
            String(repeating: "a", count: 64),
        ]
        for name in bad {
            #expect(!ClusterResource.nameValid(name), "\(name.debugDescription) should be invalid")
        }
    }
}
