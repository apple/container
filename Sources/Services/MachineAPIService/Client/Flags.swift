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

extension Flags {
    public struct MachineManagement: ParsableArguments {
        public init() {}

        @Option(name: .shortAndLong, help: "Set arch if image can target multiple architectures")
        public var arch: String = Arch.hostArchitecture().rawValue

        @Option(name: .long, help: "Set OS if image can target multiple operating systems")
        public var os = "linux"

        @Option(name: .long, help: "Platform for the image if it's multi-platform. This takes precedence over --os and --arch")
        public var platform: String?
    }
}
