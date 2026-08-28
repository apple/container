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
    func dumpNodeDiagnostics(node: String) {
        print("=== NODE DIAGNOSTICS [\(node)] ===")
        let cmds: [(label: String, args: [String])] = [
            ("ip-link", ["ip", "link", "show"]),
            ("iptables-mss", ["iptables", "-t", "mangle", "-L", "-n", "-v"]),
            ("containerd", ["systemctl", "status", "containerd", "--no-pager", "-l"]),
            ("kubelet-log", ["journalctl", "-u", "kubelet", "--no-pager", "-n", "60"]),
            ("crictl-images", ["crictl", "images"]),
        ]
        for (label, args) in cmds {
            if let r = try? self.run(["exec", node] + args) {
                let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let err = r.error.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[\(label)] exit=\(r.status)")
                if !out.isEmpty { print(out) }
                if !err.isEmpty { print("stderr: \(err)") }
            }
        }
        print("=== END NODE DIAGNOSTICS ===")
    }
}
