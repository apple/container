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
import Foundation

enum RunOptions: String {
    case mount = "--mount"
    case network = "--network"
}

enum MountOptionNames: String {
    case type = "type"
    case source = "source"
    case from = "from"
    case target = "target"
    case dst = "dst"
    case destination = "destination"

    // permissions related
    case readonly = "readonly"
    case ro = "ro"
    case readwrite = "readwrite"
    case rw = "rw"
    case uid = "uid"
    case gid = "gid"
    case mode = "mode"
    case size = "size"

    case sharing = "sharing"
    case required = "required"
    case env = "env"
    case id = "id"
}

extension MountType {
    var allowedOptions: Set<MountOptionNames> {
        switch self {
        case .bind:
            return [.source, .from, .target, .destination, .dst, .readwrite, .rw]
        case .cache:
            return [.id, .target, .destination, .dst, .readonly, .ro, .sharing, .from, .source, .mode, .gid, .uid]
        case .tmpfs:
            return [.target, .dst, .destination, .size]
        case .secret:
            return [.id, .target, .dst, .destination, .env, .required, .mode, .uid, .gid]
        case .ssh:
            return [.id, .target, .dst, .destination, .required, .mode, .uid, .gid]
        }
    }
}

/// RunMount represents a mount option with its suboptions from a docker RUN instruction
struct RunMount: Equatable {
    var type: MountType?
    var source: String?
    var from: String?
    var id: String?
    var env: String?
    var target: String?
    var options: RunMountOptions?

    init() {}

    init(
        type: MountType? = nil,
        source: String? = nil,
        from: String? = nil,
        id: String? = nil,
        env: String? = nil,
        target: String? = nil,
        options: RunMountOptions? = nil
    ) {
        self.type = type
        self.source = source
        self.from = from
        self.id = id
        self.env = env
        self.target = target
        self.options = options
    }

    mutating internal func setOption<T>(_ keyPath: WritableKeyPath<RunMountOptions, T?>, _ value: T) throws {
        guard self.options?[keyPath: keyPath] == nil else {
            throw ParseError.invalidOption("\(keyPath):\(value)")
        }
        if self.options == nil {
            self.options = RunMountOptions()
        }
        if self.options?[keyPath: keyPath] != nil {
            throw ParseError.duplicateOptionSet("\(keyPath):\(value)")
        }
        self.options?[keyPath: keyPath] = value
    }

    mutating internal func setField<T>(_ keyPath: WritableKeyPath<RunMount, T?>, _ value: T) throws {
        if self[keyPath: keyPath] != nil {
            throw ParseError.invalidOption("\(keyPath)")
        }
        self[keyPath: keyPath] = value
    }

    /// Validate required fields are set and set any defaults iff they are not already set
    mutating internal func finalize() throws {
        switch self.type {
        case .bind:
            if self.target == nil {
                throw ParseError.missingRequiredField(MountOptionNames.target.rawValue)
            }
            if self.source == nil {
                try self.setField(\.source, "/")
            }
            if self.options?.readonly == nil {
                try self.setOption(\.readonly, true)
            }
        case .cache:
            if self.target == nil {
                throw ParseError.missingRequiredField(MountOptionNames.target.rawValue)
            }
            if self.id == nil {
                try self.setField(\.id, self.target!)
            }
            if self.options?.readonly == nil {
                try self.setOption(\.readonly, false)
            }
            if self.options?.sharing == nil {
                try self.setOption(\.sharing, .shared)
            }
            if self.from == nil {
                try self.setField(\.from, "")
            }
            if self.source == nil {
                try self.setField(\.source, "/")
            }
            if self.options?.mode == nil {
                try self.setOption(\.mode, 0755)
            }
            if self.options?.uid == nil {
                try self.setOption(\.uid, 0)
            }
            if self.options?.gid == nil {
                try self.setOption(\.gid, 0)
            }
        case .tmpfs:
            if self.target == nil {
                throw ParseError.missingRequiredField(MountOptionNames.target.rawValue)
            }
            if self.options?.readonly == nil {
                try self.setOption(\.readonly, false)
            }
        case .secret:
            if self.target == nil {
                if self.env == nil {
                    guard let id = self.id else {
                        throw ParseError.missingRequiredField("id must be set when target and env are unset")
                    }
                    try self.setField(\.target, "/run/secrets/\(id)")
                }
            }
            if id == nil {
                guard let target = self.target else {
                    throw ParseError.missingRequiredField("target must be set when id is unset")
                }
                let targetURL = URL(string: target)
                guard let targetURL = targetURL else {
                    throw ParseError.invalidOption("target is not a valid url \(target)")
                }
                try self.setField(\.id, targetURL.lastPathComponent)
            }
            if self.options?.readonly == nil {
                try self.setOption(\.readonly, true)
            }
            if self.options?.required == nil {
                try self.setOption(\.required, false)
            }
            if self.options?.mode == nil {
                try self.setOption(\.mode, 0400)
            }
            if self.options?.uid == nil {
                try self.setOption(\.uid, 0)
            }
            if self.options?.gid == nil {
                try self.setOption(\.gid, 0)
            }
        case .ssh:
            if self.id == nil {
                try self.setField(\.id, "default")
            }
            if self.target == nil {
                // TODO katiewasnothere add sufix based on number of agents added
                try self.setField(\.target, "/run/buildkit/ssh_agent")
            }
            if self.options?.readonly == nil {
                try self.setOption(\.readonly, true)
            }
            if self.options?.required == nil {
                try self.setOption(\.required, false)
            }
            if self.options?.mode == nil {
                try self.setOption(\.mode, 0600)
            }
            if self.options?.uid == nil {
                try self.setOption(\.uid, 0)
            }
            if self.options?.gid == nil {
                try self.setOption(\.gid, 0)
            }
        default:
            throw ParseError.invalidOption("unsupported mount type \(String(describing: self.type))")
        }
    }
}

/// RunMountOptions represent the suboptions set on a RUN mount option
struct RunMountOptions: Equatable {
    var readonly: Bool?
    var required: Bool?
    var uid: UInt32?
    var gid: UInt32?
    var mode: UInt32?
    var size: UInt32?
    var sharing: SharingMode?

    init() {}

    init(
        readonly: Bool? = nil,
        required: Bool? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        mode: UInt32? = nil,
        size: UInt32? = nil,
        sharing: SharingMode? = nil
    ) {
        self.readonly = readonly
        self.required = required
        self.uid = uid
        self.gid = gid
        self.mode = mode
        self.size = size
        self.sharing = sharing
    }
}

/// RunInstruction represents a RUN instruction from a dockerfile
struct RunInstruction: DockerInstruction, Equatable {
    let command: Command
    let mounts: [RunMount]
    let network: NetworkMode

    init() {
        self.command = .shell("")
        self.mounts = []
        self.network = .default
    }

    init(command: Command, rawMounts: [String], network: String?) throws {
        self.command = command
        self.network = try RunInstruction.parseNetworkMode(mode: network)
        var parsedMounts: [RunMount] = []
        for m in rawMounts {
            parsedMounts.append(try RunInstruction.parseMount(m))
        }
        self.mounts = parsedMounts
    }

    static internal func parseNetworkMode(mode: String?) throws -> NetworkMode {
        guard let mode = mode else {
            return .default
        }
        guard let nMode = NetworkMode(rawValue: mode) else {
            throw ParseError.invalidOption(mode)
        }
        return nMode
    }

    static internal func parseMount(_ rawMount: String) throws -> RunMount {
        let components = rawMount.components(separatedBy: ",")
        if components.isEmpty {
            throw ParseError.invalidOption("no options set on mount")
        }

        var runMount = RunMount()
        for c in components {
            let optionComps = c.components(separatedBy: "=")
            guard optionComps.count == 2 else {
                throw ParseError.invalidOption("option \(c) is not in the form key=value")
            }
            guard optionComps[1] != "" else {
                throw ParseError.invalidOption("option \(c) is not in the form key=value")
            }
            let key = optionComps[0]
            let value = optionComps[1]
            guard let mountOption = MountOptionNames(rawValue: key) else {
                throw ParseError.invalidOption("option \(key) is not supported")
            }

            if let type = runMount.type {
                guard type.allowedOptions.contains(mountOption) else {
                    throw ParseError.invalidOption("option \(mountOption) is not supported for type \(type)")
                }
            } else {
                if let mountType = MountType(rawValue: value) {
                    runMount.type = mountType
                    continue
                } else {
                    // still need to eval this option, so we need to go to the switch
                    // statement from here
                    runMount.type = .bind
                }
            }

            switch mountOption {
            case .id:
                try runMount.setField(\.id, value)
            case .env:
                try runMount.setField(\.env, value)
            case .source:
                try runMount.setField(\.source, value)
            case .from:
                try runMount.setField(\.from, value)
            case .dst, .target, .destination:
                try runMount.setField(\.target, value)
            case .readonly, .ro:
                guard let readonly = Bool(value) else {
                    throw ParseError.invalidBoolOption(value)
                }
                try runMount.setOption(\.readonly, readonly)
            case .readwrite, .rw:
                guard let readwrite = Bool(value) else {
                    throw ParseError.invalidBoolOption(value)
                }
                try runMount.setOption(\.readonly, !readwrite)
            case .gid:
                guard let gid = UInt32(value) else {
                    throw ParseError.invalidUint32Option(value)
                }
                try runMount.setOption(\.gid, gid)
            case .uid:
                guard let uid = UInt32(value) else {
                    throw ParseError.invalidUint32Option(value)
                }
                try runMount.setOption(\.uid, uid)
            case .mode:
                guard let mode = UInt32(value) else {
                    throw ParseError.invalidUint32Option(value)
                }
                try runMount.setOption(\.mode, mode)
            case .size:
                guard let size = UInt32(value) else {
                    throw ParseError.invalidUint32Option(value)
                }
                try runMount.setOption(\.size, size)
            case .sharing:
                guard let sharing = SharingMode(rawValue: value) else {
                    throw ParseError.invalidOption("invalid sharing type \(value)")
                }
                try runMount.setOption(\.sharing, sharing)
            case .required:
                guard let requiredVal = Bool(value) else {
                    throw ParseError.invalidBoolOption(value)
                }
                try runMount.setOption(\.required, requiredVal)
            default:
                throw ParseError.invalidOption("\(key) unsupported")
            }
        }

        try runMount.finalize()
        return runMount
    }

    func accept(_ visitor: DockerInstructionVisitor) throws {
        try visitor.visit(self)
    }
}
