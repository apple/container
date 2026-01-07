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

public enum NetworkRoutes: String {
    /// Return the current state of the network.
    case state = "com.apple.container.network/state"
    /// Allocates parameters for attaching a sandbox to the network.
    case allocate = "com.apple.container.network/allocate"
    /// Deallocates parameters for attaching a sandbox to the network.
    case deallocate = "com.apple.container.network/deallocate"
    /// Disables the allocator if no sandboxes are attached.
    case disableAllocator = "com.apple.container.network/disableAllocator"
    /// Retrieves the allocation for a hostname.
    case lookup = "com.apple.container.network/lookup"
}
