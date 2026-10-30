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

import Foundation
import GRPCCore

/// The node's local store with reads that fall back to the host. Writes, walks
/// and deletes go to the local store only, so containerd's garbage collection
/// never reaches the host.
struct TieredStore: Sendable {
    let local: LocalStore
    let host: any HostStore
    let hostReads: HostReadCache

    init(local: LocalStore, host: any HostStore) {
        self.local = local
        self.host = host
        self.hostReads = HostReadCache(host: host)
    }

    func info(digest: String) async throws -> BlobInfo {
        do {
            return try await local.info(digest: digest)
        } catch let error as RPCError where error.code == .notFound {
            let size = try await host.size(digest: digest)
            let unknown = Date(timeIntervalSince1970: 0)
            return BlobInfo(digest: digest, size: size, createdAt: unknown, updatedAt: unknown)
        }
    }

    /// Returns a blob's size for reading it. A host blob's size is cached, so
    /// containerd's many small reads of one blob ask the host once.
    func readSize(digest: String) async throws -> Int64 {
        do {
            return try await local.info(digest: digest).size
        } catch let error as RPCError where error.code == .notFound {
            return try await hostReads.size(digest: digest)
        }
    }

    /// Returns up to `length` bytes of a blob starting at `offset`. A host
    /// read may return fewer bytes, ending at a cache window.
    func read(digest: String, offset: Int64, length: Int) async throws -> Data {
        do {
            return try await local.read(digest: digest, offset: offset, length: length)
        } catch let error as RPCError where error.code == .notFound {
            return try await hostReads.read(digest: digest, offset: offset, length: length)
        }
    }
}
