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

import ContainerXPC

/// AllocatedAttachment represents a network attachment that has been allocated for use
/// by a container and any additional relevant data needed for a sandbox to properly
/// configure networking on container bootstrap.
public struct AllocatedAttachment: Sendable {
    public let attachment: Attachment
    public let additionalData: XPCMessage?
    public let pluginInfo: NetworkPluginInfo

    public init(attachment: Attachment, additionalData: XPCMessage?, pluginInfo: NetworkPluginInfo) {
        self.attachment = attachment
        self.additionalData = additionalData
        self.pluginInfo = pluginInfo
    }
}
