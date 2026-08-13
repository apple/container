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

@testable import ContainerCompose

@Suite("Compose completions")
struct ComposeCompletionTests {
    @Test
    func bashDelegatesNonComposeCompletion() throws {
        let probe = """
            _previous_container_completion() { COMPREPLY=(previous); }
            complete -o default -F _previous_container_completion container
            \(ComposeCompletionProvider.script(for: .bash))
            COMP_WORDS=(container list)
            COMP_CWORD=2
            COMPREPLY=()
            _container_compose_complete
            [[ "${COMPREPLY[0]}" == previous ]]
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", probe]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test(arguments: ComposeCompletionShell.allCases)
    func pluginOptionsAreOnlyOfferedBeforeAComposeSubcommand(shell: ComposeCompletionShell) {
        let script = ComposeCompletionProvider.script(for: shell)

        #expect(ComposeCompletionProvider.pluginOptions.contains("--socket-path"))
        #expect(ComposeCompletionProvider.pluginOptions.contains("--completions"))
        #expect(!ComposeCompletionProvider.composeOptions.contains("--socket-path"))
        #expect(!ComposeCompletionProvider.composeOptions.contains("--completions"))
        #expect(script.components(separatedBy: ComposeCompletionProvider.pluginOptions).count == 2)

        switch shell {
        case .bash:
            #expect(script.contains("if (( COMP_CWORD <= 2 )); then"))
            #expect(script.contains("_container_compose_previous_completion"))
        case .zsh:
            #expect(script.contains("if (( CURRENT == 3 )); then"))
            #expect(script.contains("_container_compose_previous_completion"))
        case .fish:
            #expect(script.contains("test (count (commandline -opc)) -eq 2"))
            #expect(script.contains("test (count (commandline -opc)) -gt 2"))
            #expect(script.contains("test (commandline -opc)[2] = compose"))
        }
    }
}
