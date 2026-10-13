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

import ContainerTestSupport
import Foundation

extension ContainerFixture {
    @discardableResult
    func kubectl(node: String, args: [String]) throws -> (output: String, status: Int32) {
        print("[k8s] kubectl \(args.joined(separator: " ")) (node: \(node))")
        let result = try self.run(["exec", node, "kubectl"] + args)
        print("[k8s] kubectl exit=\(result.status) output=\(result.output.prefix(120).trimmingCharacters(in: .whitespacesAndNewlines))")
        let filteredStderr = result.error.components(separatedBy: "\n")
            .filter { !$0.contains("Warning! Running debug build") && !$0.isEmpty }
            .joined(separator: "\n")
        if !filteredStderr.isEmpty {
            print("[k8s] kubectl stderr: \(filteredStderr.prefix(300))")
        }
        return (result.output, result.status)
    }
}
