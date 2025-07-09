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

import ArgumentParser
import ContainerClient

extension Application {
    struct DNSDefault: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "default",
            abstract: "Set or unset the default local DNS domain",
            subcommands: [
                DefaultSetCommand.self,
                DefaultUnsetCommand.self,
                DefaultInspectCommand.self,
            ]
        )

        struct DefaultSetCommand: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "set",
                abstract: "Set the default local DNS domain"

            )

            @Argument(help: "the default `--domain-name` to use for the `create` or `run` command")
            var domainName: String

            func run() async throws {
                ClientDefaults.set(value: domainName, key: .defaultDNSDomain)
                print(domainName)
            }
        }

        struct DefaultUnsetCommand: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "unset",
                abstract: "Unset the default local DNS domain",
                aliases: ["clear"]
            )

            func run() async throws {
                ClientDefaults.unset(key: .defaultDNSDomain)
                print("Unset the default local DNS domain")
            }
        }

        struct DefaultInspectCommand: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "inspect",
                abstract: "Display the default local DNS domain"
            )

            func run() async throws {
                print(ClientDefaults.getOptional(key: .defaultDNSDomain) ?? "")
            }
        }
    }
}
