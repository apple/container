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

struct ExposeInstruction: DockerInstruction {
    let ports: [PortSpec]

    init(_ rawPorts: [String]) throws {
        self.ports = try rawPorts.map(parsePort)
    }

    internal init(ports: [PortSpec]) {
        self.ports = ports
    }

    func accept(_ visitor: DockerInstructionVisitor) throws {
        try visitor.visit(self)
    }
}

func parsePort(_ p: String) throws -> PortSpec {
    let parts = p.split(separator: "/", maxSplits: 1).map(String.init)
    guard let rangePart = parts.first, !rangePart.isEmpty else {
        throw ParseError.invalidOption(p)
    }

    // parse the port range
    let range = rangePart.split(separator: "-", maxSplits: 1)
    guard let port = UInt16(range[0]), port != 0 else {
        throw ParseError.invalidOption(p)
    }

    // parse the end of the range if it exists
    let end = range.count == 2 ? UInt16(range[1]) : nil
    if range.count == 2, end == nil {
        throw ParseError.invalidOption(p)
    }

    if end != nil, end == 0 {
        throw ParseError.invalidOption(p)
    }

    // parse the protocol if one was specified
    let protocolType: PortSpec.NetworkProtocol = try {
        if parts.count == 2 {
            guard let proto = PortSpec.NetworkProtocol(rawValue: String(parts[1]).lowercased()) else {
                throw ParseError.invalidOption(p)
            }
            return proto
        }
        return .tcp
    }()

    return PortSpec(port: port, endPort: end, protocol: protocolType)
}
