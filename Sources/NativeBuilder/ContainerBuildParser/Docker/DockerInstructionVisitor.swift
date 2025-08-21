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

protocol InstructionVisitor {
    func visit(_ from: FromInstruction) throws
    func visit(_ run: RunInstruction) throws
    func visit(_ copy: CopyInstruction) throws
    func visit(_ cmd: CMDInstruction) throws
    func visit(_ label: LabelInstruction) throws
    func visit(_ expose: ExposeInstruction) throws
    func visit(_ arg: ArgInstruction) throws
    // TODO: These instructions have to perform the ARG substitution checked in `testSimpleDockerfileArgInInstructions()`:
    // - ADD
    // - ENV
    // - STOPSIGNAL
    // - USER
    // - VOLUME
    // - WORKDIR
    // - ONBUILD
    // - ENTRYPOINT
}

/// DockerInstructionVisitor visits each provided DockerInstruction and builds a
/// build graph from the instructions.
public class DockerInstructionVisitor: InstructionVisitor {

    internal let graphBuilder: GraphBuilder

    init() {
        self.graphBuilder = GraphBuilder()
    }

    func buildGraph(from: [any DockerInstruction]) throws -> BuildGraph {
        for instruction in from {
            try instruction.accept(self)
        }
        return try graphBuilder.build()
    }
}

extension DockerInstructionVisitor {
    private func substituteArgsInCommand(_ command: Command) -> Command {
        switch command {
        case .shell(let cmd):
            let substitutedCmd = graphBuilder.substituteArgs(cmd, inFromContext: false)
            return .shell(substitutedCmd)
        case .exec(let args):
            let substitutedArgs = args.map { graphBuilder.substituteArgs($0, inFromContext: false) }
            return .exec(substitutedArgs)
        }
    }

    func visit(_ from: FromInstruction) throws {
        let imageString = graphBuilder.substituteArgs(from.image, inFromContext: true)

        guard let imageRef = ImageReference(parsing: imageString) else {
            throw ParseError.invalidImage(imageString)
        }

        if let stageName = from.stageName {
            try graphBuilder.stage(name: stageName, from: imageRef, platform: from.platform)
        } else {
            try graphBuilder.stage(from: imageRef, platform: from.platform)
        }
    }

    func visit(_ run: RunInstruction) throws {
        var mounts: [Mount] = []
        for m in run.mounts {
            guard let type = m.type else {
                throw ParseError.unexpectedValue
            }

            let mountSource: MountSource?
            switch m.type {
            case .bind, .cache:
                guard let source = m.source else {
                    throw ParseError.missingRequiredField(MountOptionNames.source.rawValue)
                }
                if let from = m.from, from != "" {
                    if let _ = graphBuilder.getStage(stageName: from) {
                        mountSource = .stage(.named(from), path: source)
                    } else if let context = graphBuilder.resolveArg(key: from, inFromContext: false) {
                        mountSource = .context(context, path: source)
                    } else {
                        // mount source is an image name
                        guard let imageRef = ImageReference(parsing: from) else {
                            throw ParseError.invalidImage(from)
                        }
                        mountSource = .image(imageRef, path: source)
                    }
                } else {
                    // from was not set or is empty, default is local source
                    mountSource = .local(source)
                }
            case .secret:
                mountSource = .secret(m.id!)
            case .ssh:
                mountSource = .sshAgent
            default:
                // this covers .tmpfs case as well
                mountSource = nil
            }

            guard let options = m.options else {
                throw ParseError.unexpectedValue
            }

            guard let readonly = options.readonly else {
                throw ParseError.unexpectedValue
            }

            let mountOptions = MountOptions(
                readOnly: readonly,
                uid: options.uid,
                gid: options.gid,
                mode: options.mode,
                size: options.size,
                sharing: options.sharing,
                required: options.required)

            let graphMount = Mount(
                type: type,
                target: m.target,
                envTarget: m.env,
                source: mountSource,
                options: mountOptions)

            mounts.append(graphMount)
        }

        let substitutedCommand = substituteArgsInCommand(run.command)
        try graphBuilder.runWithCmd(substitutedCommand, mounts: mounts)
    }

    func visit(_ copy: CopyInstruction) throws {
        // TODO katiewasnothere: plumb through "--link" option

        let substitutedSources = copy.sources.map { graphBuilder.substituteArgs($0, inFromContext: false) }
        let substitutedDestination = graphBuilder.substituteArgs(copy.destination, inFromContext: false)

        if let from = copy.from {
            var source: FilesystemSource
            if let _ = graphBuilder.getStage(stageName: from) {
                source = .stage(.named(from), paths: substitutedSources)
            } else if let context = graphBuilder.resolveArg(key: from, inFromContext: false) {
                source = .context(ContextSource(name: context, paths: substitutedSources))
            } else {
                guard let imageRef = ImageReference(parsing: from) else {
                    throw ParseError.invalidImage(from)
                }
                source = .image(imageRef, paths: substitutedSources)
            }
            try graphBuilder.copy(from: source, to: substitutedDestination, chown: copy.chown, chmod: copy.chmod)
            return
        }
        try graphBuilder.copyFromContext(paths: substitutedSources, to: substitutedDestination, chown: copy.chown, chmod: copy.chmod)
    }

    func visit(_ cmd: CMDInstruction) throws {
        let substitutedCommand = substituteArgsInCommand(cmd.command)
        try graphBuilder.cmd(substitutedCommand)
    }

    func visit(_ label: LabelInstruction) throws {
        let substitutedLabels = label.labels.mapValues { graphBuilder.substituteArgs($0, inFromContext: false) }
        try graphBuilder.labelBatch(labels: substitutedLabels)
    }

    func visit(_ expose: ExposeInstruction) throws {
        let substitutedPortStrings = expose.ports.map { graphBuilder.substituteArgs($0, inFromContext: false) }
        let substitutedPorts = try substitutedPortStrings.map(parsePort)
        try graphBuilder.expose(substitutedPorts)
    }

    func visit(_ arg: ArgInstruction) throws {
        for argDef in arg.args {
            let substitutedDefaultValue: String?
            if let defaultValue = argDef.defaultValue {
                substitutedDefaultValue = graphBuilder.substituteArgs(defaultValue, inFromContext: !graphBuilder.hasActiveStage)
            } else {
                substitutedDefaultValue = nil
            }

            if graphBuilder.hasActiveStage {
                try graphBuilder.arg(argDef.name, defaultValue: substitutedDefaultValue)
            } else {
                graphBuilder.fromOnlyArg(argDef.name, defaultValue: substitutedDefaultValue)
            }
        }
    }
}
