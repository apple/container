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

import ContainerAPIService
import Synchronization

/// A `VolumeCredentialStore` that keeps credentials in memory, for tests that must not touch the keychain.
final class InMemoryVolumeCredentialStore: VolumeCredentialStore, Sendable {
    struct Failure: Error {}

    private let credentials = Mutex<[String: VolumeCredential]>([:])
    private let failSave: Bool

    init(failSave: Bool = false) {
        self.failSave = failSave
    }

    func save(volume: String, credential: VolumeCredential) throws {
        if failSave {
            throw Failure()
        }
        credentials.withLock { $0[volume] = credential }
    }

    func lookup(volume: String) throws -> VolumeCredential? {
        credentials.withLock { $0[volume] }
    }

    func delete(volume: String) throws {
        credentials.withLock { $0[volume] = nil }
    }

    var count: Int {
        credentials.withLock { $0.count }
    }
}
