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
import ContainerizationError
import Foundation

/// The kind of name that matched a lookup on a network.
public enum NetworkMatchKind: Sendable, Equatable {
    /// The hostname of an attachment.
    case hostname
    /// An exact alias of an attachment.
    case alias
    /// A subtree alias of an attachment, with the number of labels in its base.
    case subtree(baseLabelCount: Int)
}

/// The attachment that a name resolved to on a network, and how the name matched.
public struct NetworkMatch: Sendable {
    public let attachment: Attachment
    public let kind: NetworkMatchKind

    public init(attachment: Attachment, kind: NetworkMatchKind) {
        self.attachment = attachment
        self.kind = kind
    }
}

extension XPCMessage {
    /// Sets the aliases of an attachment, in their normalized string form.
    public func setAliases(_ aliases: [String]) throws {
        self.set(key: NetworkKeys.aliases.rawValue, value: try JSONEncoder().encode(aliases))
    }

    /// The aliases in the message, which are empty if the message has none.
    public func aliases() throws -> [String] {
        guard let data = self.dataNoCopy(key: NetworkKeys.aliases.rawValue) else {
            return []
        }
        return try JSONDecoder().decode([String].self, from: data)
    }

    /// Sets how a name matched.
    public func setMatchKind(_ kind: NetworkMatchKind) {
        switch kind {
        case .hostname:
            self.set(key: NetworkKeys.matchKind.rawValue, value: "hostname")
        case .alias:
            self.set(key: NetworkKeys.matchKind.rawValue, value: "alias")
        case .subtree(let baseLabelCount):
            self.set(key: NetworkKeys.matchKind.rawValue, value: "subtree")
            self.set(key: NetworkKeys.baseLabelCount.rawValue, value: Int64(baseLabelCount))
        }
    }

    /// How a name matched.
    public func matchKind() throws -> NetworkMatchKind {
        guard let kind = self.string(key: NetworkKeys.matchKind.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "no match kind in message")
        }
        switch kind {
        case "hostname":
            return .hostname
        case "alias":
            return .alias
        case "subtree":
            return .subtree(baseLabelCount: Int(self.int64(key: NetworkKeys.baseLabelCount.rawValue)))
        default:
            throw ContainerizationError(.invalidArgument, message: "unknown match kind \"\(kind)\" in message")
        }
    }
}
