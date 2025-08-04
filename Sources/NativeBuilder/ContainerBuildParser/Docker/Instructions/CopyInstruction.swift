//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import ContainerBuildIR

enum CopyOptions: String {
    case from = "--from"
    case chown = "--chown"
    case chmod = "--chmod"
    case link = "--link"
}

struct CopyInstruction: DockerInstruction {
    let sources: [String]
    let destination: String
    let from: String?
    let chown: Ownership?
    let chmod: Permissions?

    internal init(
        sources: [String],
        destination: String,
        from: String? = nil,
        ownership: Ownership = Ownership(user: .numeric(id: 0), group: .numeric(id: 0)),
        permissions: Permissions? = nil
    ) throws {
        self.sources = sources
        self.destination = destination
        self.from = from
        self.chown = ownership
        self.chmod = permissions
    }

    init(
        sources: [String],
        destination: String? = nil,
        from: String? = nil,
        ownership: String? = nil,
        permissions: String? = nil
    ) throws {

        guard !sources.isEmpty else {
            throw ParseError.missingRequiredField("source")
        }
        guard let destination = destination else {
            throw ParseError.missingRequiredField("destination")
        }
        self.sources = sources
        self.destination = destination
        self.from = from
        self.chown = try CopyInstruction.parseOwnership(input: ownership)
        self.chmod = try CopyInstruction.parsePermissions(input: permissions)
    }

    static internal func parseOwnership(input: String?) throws -> Ownership? {
        guard let input = input, !input.isEmpty else {
            return Ownership(user: .numeric(id: 0), group: .numeric(id: 0))
        }
        var user: OwnershipID? = nil
        var group: OwnershipID? = nil

        let components = input.components(separatedBy: ":")
        guard components.count <= 2 else {
            throw ParseError.invalidOption(input)
        }
        user = parseID(id: components[0])
        if components.count == 2 {
            group = parseID(id: components[1])
        }
        if user == nil && group == nil {
            throw ParseError.invalidOption(input)
        }
        return Ownership(user: user, group: group)
    }

    static private func parseID(id: String) -> OwnershipID? {
        if id == "" {
            return nil
        }
        if let numberID = UInt32(id) {
            return .numeric(id: numberID)
        }
        return .named(id: id)
    }

    static internal func parsePermissions(input: String?) throws -> Permissions? {
        guard let input = input else {
            return nil
        }
        guard let mode = UInt32(input) else {
            throw ParseError.invalidUint32Option(input)
        }
        return Permissions.mode(mode)
    }

    func accept(_ visitor: DockerInstructionVisitor) throws {
        try visitor.visit(self)
    }
}
