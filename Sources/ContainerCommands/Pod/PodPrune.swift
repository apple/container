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
import ContainerResource
import Foundation

extension Application.PodCommand {
    public struct PodPrune: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove anonymous pods with no containers in them")

        @Flag(name: .shortAndLong, help: "Remove pods that were named too, not only anonymous ones")
        var all = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            let allPods = try await ClientPod.list()

            // Find all pods that hold no container
            let client = ContainerClient()
            let containers = try await client.list()
            var podsInUse = Set<String>()
            for container in containers {
                podsInUse.insert(container.configuration.pod)
            }

            // A pod someone named is theirs, and an empty one is still theirs to
            // put something in, so a prune leaves it alone unless asked for all
            // of them. A pod nobody named was made because a container needed a
            // machine, and is of no use to anyone once no container is in it.
            // https://github.com/containerd/nerdctl/blob/main/pkg/cmd/volume/prune.go
            let podsToPrune = allPods.filter { pod in
                guard !podsInUse.contains(pod.configuration.id) else {
                    return false
                }
                return all || pod.configuration.isAnonymous
            }

            var prunedPods = [String]()

            for pod in podsToPrune {
                do {
                    try await ClientPod.delete(pod.configuration.id, force: true)
                    prunedPods.append(pod.configuration.id)
                } catch {
                    log.error(
                        "failed to prune pod",
                        metadata: [
                            "id": "\(pod.configuration.id)",
                            "error": "\(error)",
                        ]
                    )
                }
            }

            if !prunedPods.isEmpty {
                print("Deleted Pods:")
                for pod in prunedPods {
                    print(pod)
                }
            }
        }
    }
}
