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

import ContainerAPIClient
import ContainerResource
import Logging

/// The resources a container was given rather than asked for by name.
///
/// A volume mounted without a name, and the pod a container that named none was
/// given, are both made because the container needed one and are of no use to
/// anyone once it is gone. They are read off the container before it is removed,
/// since the container is what records them, and taken away after.
///
/// nerdctl removes these with the container when the container is removed with
/// its volumes, when it was run to be removed on exit, and when containers are
/// pruned, and leaves them alone on a plain removal.
/// https://github.com/containerd/nerdctl/blob/main/pkg/cmd/container/remove.go
public struct AnonymousResources: Sendable {
    let volumes: [String]
    let pod: String?

    /// Read what a container was given, before it is removed.
    public static func given(to container: ContainerSnapshot) async -> AnonymousResources {
        var volumes: [String] = []
        for mount in container.configuration.mounts {
            guard mount.isVolume, let name = mount.volumeName else {
                continue
            }
            guard let volume = try? await ClientVolume.inspect(name), volume.isAnonymous else {
                continue
            }
            volumes.append(name)
        }

        let pod = try? await ClientPod.inspect(container.configuration.pod)
        return AnonymousResources(
            volumes: volumes,
            pod: (pod?.configuration.isAnonymous ?? false) ? pod?.configuration.id : nil
        )
    }

    /// Take them away, now that the container that was given them is gone.
    ///
    /// A resource that will not go is reported and passed over: the container it
    /// belonged to is already gone, so failing here would fail a removal that
    /// has already happened.
    public func remove(log: Logger) async {
        for volume in volumes {
            do {
                try await ClientVolume.delete(name: volume)
            } catch {
                log.warning(
                    "failed to remove an anonymous volume",
                    metadata: ["volume": "\(volume)", "error": "\(error)"])
            }
        }
        if let pod {
            do {
                try await ClientPod.delete(pod, force: true)
            } catch {
                log.warning(
                    "failed to remove an anonymous pod",
                    metadata: ["pod": "\(pod)", "error": "\(error)"])
            }
        }
    }
}
