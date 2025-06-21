//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

//

import Foundation
import Testing

extension TestCLIBuildBase {
    class CLIBuilderLifecycleTest: TestCLIBuildBase {
        override init() throws {}
        @Test func testBuilderStartStopCommand() throws {
            #expect(throws: Never.self) {
                try self.builderStart()
                try self.waitForBuilderRunning()
                let status = try self.getContainerStatus("buildkit")
                #expect(status == "running", "BuildKit container is not running")
            }
            #expect(throws: Never.self) {
                try self.builderStop()
                let status = try self.getContainerStatus("buildkit")
                #expect(status == "stopped", "BuildKit container is not stopped")
            }
        }
    }
}
