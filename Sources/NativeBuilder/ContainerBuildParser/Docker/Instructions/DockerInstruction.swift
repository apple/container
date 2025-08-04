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
import ContainerizationOCI

/// DockerInstruction represents a single docker instruction with its given options
/// and arguments. Instructions are "visited" to add to a build graph.
protocol DockerInstruction: Sendable, Equatable {
    func accept(_ visitor: DockerInstructionVisitor) throws
}

enum FromOptions: String {
    case platform = "--platform"
}

struct FromInstruction: DockerInstruction {
    let image: ImageReference
    let platform: Platform?
    let stageName: String?

    init(image: String, platform: String? = nil, stageName: String? = nil) throws {
        guard let imageRef = ImageReference(parsing: image) else {
            throw ParseError.invalidImage(image)
        }

        var platformSpec = Platform.current
        if let platform = platform {
            platformSpec = try Platform(from: platform)
        }
        self.image = imageRef
        self.platform = platformSpec
        self.stageName = stageName
    }

    func accept(_ visitor: DockerInstructionVisitor) throws {
        try visitor.visit(self)
    }
}

/// DockerInstructionName defines a dockerfile instruction such as FROM, RUN, etc.
enum DockerInstructionName: String {
    case FROM = "from"
    case RUN = "run"
    case COPY = "copy"
    case CMD = "cmd"
    case LABEL = "label"
}

/// DockerKeyword defines words that are used as keywords within a line of a dockerfile
/// to provide additional instruction
enum DockerKeyword: String {
    case AS = "as"
}

struct CMDInstruction: DockerInstruction {
    let command: Command

    func accept(_ visitor: DockerInstructionVisitor) throws {
        try visitor.visit(self)
    }
}

struct LabelInstruction: DockerInstruction {
    let labels: [String: String]
    func accept(_ visitor: DockerInstructionVisitor) throws {
        try visitor.visit(self)
    }
}
