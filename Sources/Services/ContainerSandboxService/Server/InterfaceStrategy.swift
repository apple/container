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
import ContainerXPC
import Containerization

/// A strategy for mapping network attachment information to a network interface.
public protocol InterfaceStrategy: Sendable {
    /// Map a client network attachment request to a network interface specification.
    ///
    /// - Parameters:
    ///   - attachment: General attachment information that is common
    ///     for all networks.
    ///   - interfaceIndex: The zero-based index of the interface.
    ///   - additionalData: If present, attachment information that is
    ///     specific for the network to which the container will attach.
    ///
    /// - Returns: An XPC message with no parameters.
    func toInterface(attachment: Attachment, interfaceIndex: Int, additionalData: XPCMessage?) throws -> Interface
}
