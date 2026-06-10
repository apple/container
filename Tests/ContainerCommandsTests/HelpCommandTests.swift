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

struct HelpCommandTests {
    @Test
    func everyStaticSubcommandReachableViaHelp() {
        func walk(_ command: ParsableCommand.Type, path: [String]) {
            let cfg = command.configuration
            var children = cfg.subcommands
            for group in cfg.groupedSubcommands {
                children.append(contentsOf: group.subcommands)
            }
            for child in children {
                guard let name = child.configuration.commandName else { continue }
                let canonical = path + [name]
                let canonicalResolved = HelpCommand.resolveSubcommand(path: canonical) != nil
                #expect(
                    canonicalResolved,
                    "help should resolve '\(canonical.joined(separator: " "))' but returned nil"
                )
                for alias in child.configuration.aliases {
                    let aliasPath = path + [alias]
                    let aliasResolved = HelpCommand.resolveSubcommand(path: aliasPath) != nil
                    #expect(
                        aliasResolved,
                        "help should resolve alias path '\(aliasPath.joined(separator: " "))' but returned nil"
                    )
                }
                walk(child, path: canonical)
            }
        }
        walk(Application.self, path: [])
    }

    @Test
    func unknownSubcommandReturnsNil() {
        let unknownResolved = HelpCommand.resolveSubcommand(path: ["nonexistent"]) == nil
        #expect(unknownResolved)
        let nestedUnknownResolved = HelpCommand.resolveSubcommand(path: ["image", "nonexistent"]) == nil
        #expect(nestedUnknownResolved)
    }
}
