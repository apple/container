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

/// Keeps what each host was given, so a host attaching again is given it back
/// after this service has been restarted.
///
/// What a lease is written to is the caller's, since a network plugin knows
/// where its own state belongs and this module holds none.
public protocol AttachmentLeaseStore: Sendable {
    /// Everything written down so far. A store that cannot be read answers
    /// with nothing, which costs the addresses their stability and no more.
    func load() async -> [AttachmentAllocator.Lease]

    /// Write down what a host was given.
    func save(_ lease: AttachmentAllocator.Lease) async
}
