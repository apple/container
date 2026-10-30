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

import ContainerizationOCI
import Crypto
import Foundation
import GRPCCore
import GRPCInProcessTransport

@testable import ClusterShim

/// A host store holding blobs and image descriptors in memory.
struct FakeHostStore: HostStore {
    var blobs: [String: Data] = [:]
    var images: [String: Descriptor] = [:]
    /// Makes every call fail as if the host store could not be reached.
    var unavailable = false

    func size(digest: String) async throws -> Int64 {
        Int64(try blob(digest: digest).count)
    }

    func read(digest: String, offset: Int64, length: Int) async throws -> Data {
        let data = try blob(digest: digest)
        let start = Int(offset)
        let end = min(start + length, data.count)
        return data.subdata(in: start..<end)
    }

    func readManifest(digest: String) async throws -> Data {
        try blob(digest: digest)
    }

    func image(reference: String) async throws -> Descriptor {
        try checkAvailable()
        guard let descriptor = images[reference] else {
            throw RPCError(code: .notFound, message: "image \(reference) not found")
        }
        return descriptor
    }

    private func blob(digest: String) throws -> Data {
        try checkAvailable()
        guard let data = blobs[digest] else {
            throw RPCError(code: .notFound, message: "blob \(digest) not found")
        }
        return data
    }

    private func checkAvailable() throws {
        if unavailable {
            throw RPCError(code: .unavailable, message: "host store unavailable")
        }
    }
}

/// Returns the `sha256:<hex>` digest of `data`.
func digest(of data: Data) -> String {
    ParsedDigest(SHA256.hash(data: data)).description
}

/// Returns a new empty directory under the temporary directory.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-shim-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Runs `body` with a client connected in-process to a server for `services`.
func withInProcessServer<Result: Sendable>(
    services: [any RegistrableRPCService],
    _ body: (GRPCClient<InProcessTransport.Client>) async throws -> Result
) async throws -> Result {
    let transport = InProcessTransport()
    return try await withGRPCServer(transport: transport.server, services: services) { _ in
        try await withGRPCClient(transport: transport.client) { client in
            try await body(client)
        }
    }
}
