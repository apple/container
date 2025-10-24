//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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
import Foundation

extension Application.VolumeCommand {
    public struct VolumePrune: AsyncParsableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove volumes with no container references")

        @OptionGroup
        var global: Flags.Global

        public func run() async throws {
            let (volumeNames, size) = try await ClientVolume.prune()
            let formatter = ByteCountFormatter()
            let freed = formatter.string(fromByteCount: Int64(size))

            if volumeNames.isEmpty {
                print("No volumes to prune")
            } else {
                print("Pruned volumes:")
                for name in volumeNames {
                    print(name)
                }
                print()
            }
            print("Reclaimed \(freed) in disk space")
        }
    }
}
