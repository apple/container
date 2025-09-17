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
import ContainerPersistence
import ContainerizationError
import Foundation

extension Application {
    struct PropertyGet: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Retrieve a property value"
        )

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "the property ID")
        var id: String

        func run() async throws {
            let value = DefaultsStore.allValues()
                .filter { id == $0.id }
                .first
            guard let value else {
                throw ContainerizationError(.invalidArgument, message: "property ID \(id) not found")
            }

            guard let val = value.value?.description else {
                return
            }

            print(val)
        }
    }
}
