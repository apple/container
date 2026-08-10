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
import ContainerCommands

@main
struct PodPlugin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pod",
        abstract: "Manage pods, machines that several containers share",
        subcommands: [
            Application.PodCommand.PodCreate.self,
            Application.PodCommand.PodStart.self,
            Application.PodCommand.PodStop.self,
            Application.PodCommand.PodDelete.self,
            Application.PodCommand.PodList.self,
            Application.PodCommand.PodInspect.self,
            Application.PodCommand.PodPrune.self,
            Application.PodCommand.PodUpdate.self,
        ]
    )
}
