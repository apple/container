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
import ContainerizationError
import Foundation

extension Application {
    struct BuilderStatus: AsyncParsableCommand {
        public static var configuration: CommandConfiguration {
            var config = CommandConfiguration()
            config.commandName = "status"
            config._superCommandName = "builder"
            config.abstract = "Print builder status"
            config.usage = "\n\t builder status [command options]"
            config.helpNames = NameSpecification(arrayLiteral: .customShort("h"), .customLong("help"))
            return config
        }

        @Flag(name: .long, help: ArgumentHelp("Display detailed status in json format"))
        var json: Bool = false

        func run() async throws {
            do {
                let container = try await ClientContainer.get(id: "buildkit")
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let jsonData = try encoder.encode(container)

                    guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                        throw ContainerizationError(.internalError, message: "failed to encode BuildKit container as json")
                    }
                    print(jsonString)
                    return
                }

                let image = container.configuration.image.reference
                let resources = container.configuration.resources
                let cpus = resources.cpus
                let memory = resources.memoryInBytes / (1024 * 1024)  // bytes to MB
                let addr = ""

                print("ID       IMAGE                           STATE   ADDR         CPUS MEMORY")
                print("\(container.id) \(image) \(container.status.rawValue.uppercased()) \(addr) \(cpus)    \(memory) MB")
            } catch {
                if error is ContainerizationError {
                    if (error as? ContainerizationError)?.code == .notFound {
                        print("builder is not running")
                        return
                    }
                }
                throw error
            }
        }
    }
}
