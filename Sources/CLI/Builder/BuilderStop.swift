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
    public struct BuilderStop: AsyncParsableCommand {
        public init() {}
        
        public static var configuration: CommandConfiguration {
            var config = CommandConfiguration()
            config.commandName = "stop"
            config._superCommandName = "builder"
            config.abstract = "Stop builder"
            config.usage = "\n\t builder stop"
            config.helpNames = NameSpecification(arrayLiteral: .customShort("h"), .customLong("help"))
            return config
        }

        public func run() async throws {
            do {
                let container = try await ClientContainer.get(id: "buildkit")
                try await container.stop()
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
