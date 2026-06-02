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

import ContainerResource
import ContainerizationOCI

extension ClientImage {
    /// Resolves, from the content store, the index descriptor and per-platform
    /// manifest content needed to build an ``ImageResource``.
    ///
    /// Manifests without a platform, or whose config/manifest cannot be
    /// fetched, are skipped. The returned content is the input expected by
    /// ``ImageResource/init(config:index:manifests:)``.
    public func resolvedManifests() async throws -> (index: Descriptor, manifests: [ImageResource.ManifestContent]) {
        let index = try await self.resolved()
        var manifests: [ImageResource.ManifestContent] = []
        for desc in try await self.index().manifests {
            guard let platform = desc.platform else {
                continue
            }
            let config: ContainerizationOCI.Image
            let manifest: ContainerizationOCI.Manifest
            do {
                config = try await self.config(for: platform)
                manifest = try await self.manifest(for: platform)
            } catch {
                continue
            }
            manifests.append(.init(descriptor: desc, manifest: manifest, config: config))
        }
        return (index, manifests)
    }
}
