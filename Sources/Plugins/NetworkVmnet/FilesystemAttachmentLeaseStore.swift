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

import ContainerNetworkServer
import ContainerPersistence
import Logging

/// Keeps what each host was given on disk, one lease to an entry, under the
/// directory belonging to the network that gave it.
struct FilesystemAttachmentLeaseStore: AttachmentLeaseStore {
    let store: FilesystemEntityStore<AttachmentAllocator.Lease>
    let log: Logger

    func load() async -> [AttachmentAllocator.Lease] {
        do {
            return try await store.list()
        } catch {
            log.warning("cannot read what hosts were given", metadata: ["error": "\(error)"])
            return []
        }
    }

    func save(_ lease: AttachmentAllocator.Lease) async {
        do {
            try await store.upsert(lease)
        } catch {
            log.warning(
                "cannot write down what a host was given",
                metadata: ["hostname": "\(lease.id)", "error": "\(error)"])
        }
    }
}
