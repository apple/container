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

import ContainerizationExtras

/// Protocol for receiving notifications when networks start or stop.
/// Used to dynamically bind/unbind DNS listeners to network gateway addresses.
public protocol NetworkDNSDelegate: Sendable {
    /// Called when a network starts and its gateway IP becomes available.
    /// - Parameter gateway: The IPv4 gateway address of the network
    func networkDidStart(gateway: IPv4Address) async

    /// Called when a network stops and its gateway IP is no longer available.
    /// - Parameter gateway: The IPv4 gateway address of the network
    func networkDidStop(gateway: IPv4Address) async
}
