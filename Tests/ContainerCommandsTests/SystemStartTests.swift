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

struct SystemStartTests {
    @Test(arguments: [true, false])
    func enableKernelInstallInstallsWithoutPrompting(isTerminal: Bool) {
        let decision = Application.SystemStart.kernelInstallDecision(kernelInstall: true, isTerminal: isTerminal) {
            Issue.record("should not prompt when --enable-kernel-install is set")
            return nil
        }
        #expect(decision == .install)
    }

    @Test(arguments: [true, false])
    func disableKernelInstallSkipsWithoutPrompting(isTerminal: Bool) {
        let decision = Application.SystemStart.kernelInstallDecision(kernelInstall: false, isTerminal: isTerminal) {
            Issue.record("should not prompt when --disable-kernel-install is set")
            return nil
        }
        #expect(decision == .skip)
    }

    @Test(arguments: ["y", "Y", ""], [true, false])
    func acceptedAnswerInstalls(answer: String, isTerminal: Bool) {
        let decision = Application.SystemStart.kernelInstallDecision(kernelInstall: nil, isTerminal: isTerminal) { answer }
        #expect(decision == .install)
    }

    @Test(arguments: ["n", "yes"], [true, false])
    func otherAnswerDeclines(answer: String, isTerminal: Bool) {
        let decision = Application.SystemStart.kernelInstallDecision(kernelInstall: nil, isTerminal: isTerminal) { answer }
        #expect(decision == .decline)
    }

    @Test
    func missingAnswerFailsWithTerminal() {
        let decision = Application.SystemStart.kernelInstallDecision(kernelInstall: nil, isTerminal: true) { nil }
        #expect(decision == .failWithoutAnswer)
    }

    @Test
    func missingAnswerSkipsWithoutTerminal() {
        let decision = Application.SystemStart.kernelInstallDecision(kernelInstall: nil, isTerminal: false) { nil }
        #expect(decision == .skipWithoutAnswer)
    }
}
