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
import ContainerAPIClient

extension Application {
    public struct MachineCommand: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "machine",
            abstract: "Manage container machines",
            discussion: """
                EXAMPLES:
                  List available images and create a container machine:
                    $ container machine create alpine:3.22 --name my-machine

                  Run commands in the container machine:
                    $ container machine run -n my-machine uname
                    $ container machine run -n my-machine -- cat /proc/cpuinfo

                  Change the container machine configuration (takes effect after restart):
                    $ container machine set -n my-machine cpus=4 memory=8G home-mount=ro
                    $ container machine stop my-machine
                    $ container machine run -n my-machine -- nproc

                  Stop and delete the container machine:
                    $ container machine stop my-machine
                    $ container machine delete my-machine
                """,
            subcommands: [
                MachineCreate.self,
                MachineDelete.self,
                MachineInspect.self,
                MachineList.self,
                MachineLogs.self,
                MachineRun.self,
                MachineSet.self,
                MachineSetDefault.self,
                MachineStop.self,
            ],
            aliases: ["m"]
        )

        public init() {}

        @OptionGroup
        public var logOptions: Flags.Logging
    }
}

extension Application.MachineCommand {
    public enum ListFormat: String, CaseIterable, ExpressibleByArgument {
        case json
        case table
    }
}
