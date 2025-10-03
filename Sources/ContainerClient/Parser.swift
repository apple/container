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

import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation

/// A parsed volume specification from user input
public struct ParsedVolume {
    public let name: String
    public let destination: String
    public let options: [String]

    public init(name: String, destination: String, options: [String] = []) {
        self.name = name
        self.destination = destination
        self.options = options
    }
}

/// Union type for parsed mount specifications
public enum VolumeOrFilesystem {
    case filesystem(Filesystem)
    case volume(ParsedVolume)
}

public struct Parser {
    public static func memoryString(_ memory: String) throws -> Int64 {
        let ram = try Measurement.parse(parsing: memory)
        let mb = ram.converted(to: .mebibytes)
        return Int64(mb.value)
    }

    public static func user(
        user: String?, uid: UInt32?, gid: UInt32?,
        defaultUser: ProcessConfiguration.User = .id(uid: 0, gid: 0)
    ) -> (user: ProcessConfiguration.User, groups: [UInt32]) {
        var supplementalGroups: [UInt32] = []
        let user: ProcessConfiguration.User = {
            if let user = user, !user.isEmpty {
                return .raw(userString: user)
            }
            if let uid, let gid {
                return .id(uid: uid, gid: gid)
            }
            if uid == nil, gid == nil {
                // Neither uid nor gid is set. return the default user
                return defaultUser
            }
            // One of uid / gid is left unspecified. Set the user accordingly
            if let uid {
                return .raw(userString: "\(uid)")
            }
            if let gid {
                supplementalGroups.append(gid)
            }
            return defaultUser
        }()
        return (user, supplementalGroups)
    }

    public static func platform(os: String, arch: String) -> ContainerizationOCI.Platform {
        .init(arch: arch, os: os)
    }

    public static func platform(from platform: String) throws -> ContainerizationOCI.Platform {
        try .init(from: platform)
    }

    public static func resources(cpus: Int64?, memory: String?) throws -> ContainerConfiguration.Resources {
        var resource = ContainerConfiguration.Resources()
        if let cpus {
            resource.cpus = Int(cpus)
        }
        if let memory {
            resource.memoryInBytes = try Parser.memoryString(memory).mib()
        }
        return resource
    }

    public static func allEnv(imageEnvs: [String], envFiles: [String], envs: [String]) throws -> [String] {
        var output: [String] = []
        output.append(contentsOf: Parser.env(envList: imageEnvs))
        for envFile in envFiles {
            let content = try Parser.envFile(path: envFile)
            output.append(contentsOf: content)
        }
        output.append(contentsOf: Parser.env(envList: envs))
        return output
    }

    public static func envFile(path: String) throws -> [String] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ContainerizationError(.notFound, message: "envfile at \(path) not found")
        }

        let data = try String(contentsOfFile: path, encoding: .utf8)
        let lines = data.components(separatedBy: .newlines)
        var envVars: [String] = []
        for line in lines {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                continue
            }
            if !line.hasPrefix("#") {
                let keyVals = line.split(separator: "=", maxSplits: 2)
                if keyVals.count != 2 {
                    continue
                }
                let key = keyVals[0].trimmingCharacters(in: .whitespaces)
                let val = keyVals[1].trimmingCharacters(in: .whitespaces)
                if key.isEmpty || val.isEmpty {
                    continue
                }
                envVars.append("\(key)=\(val)")
            }
        }
        return envVars
    }

    public static func env(envList: [String]) -> [String] {
        var envVar: [String] = []
        for env in envList {
            var env = env
            let parts = env.split(separator: "=", maxSplits: 2)
            if parts.count == 1 {
                guard let val = ProcessInfo.processInfo.environment[env] else {
                    continue
                }
                env = "\(env)=\(val)"
            }
            envVar.append(env)
        }
        return envVar
    }

    public static func labels(_ rawLabels: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for label in rawLabels {
            if label.isEmpty {
                throw ContainerizationError(.invalidArgument, message: "label cannot be an empty string")
            }
            let parts = label.split(separator: "=", maxSplits: 2)
            switch parts.count {
            case 1:
                result[String(parts[0])] = ""
            case 2:
                result[String(parts[0])] = String(parts[1])
            default:
                throw ContainerizationError(.invalidArgument, message: "invalid label format \(label)")
            }
        }
        return result
    }

    public static func process(
        arguments: [String],
        processFlags: Flags.Process,
        managementFlags: Flags.Management,
        config: ContainerizationOCI.ImageConfig?
    ) throws -> ProcessConfiguration {

        let imageEnvVars = config?.env ?? []
        let envvars = try Parser.allEnv(imageEnvs: imageEnvVars, envFiles: processFlags.envFile, envs: processFlags.env)

        let workingDir: String = {
            if let cwd = processFlags.cwd {
                return cwd
            }
            if let cwd = config?.workingDir {
                return cwd
            }
            return "/"
        }()

        let processArguments: [String]? = {
            var result: [String] = []
            var hasEntrypointOverride: Bool = false
            // ensure the entrypoint is honored if it has been explicitly set by the user
            if let entrypoint = managementFlags.entrypoint, !entrypoint.isEmpty {
                result = [entrypoint]
                hasEntrypointOverride = true
            } else if let entrypoint = config?.entrypoint, !entrypoint.isEmpty {
                result = entrypoint
            }
            if !arguments.isEmpty {
                result.append(contentsOf: arguments)
            } else {
                if let cmd = config?.cmd, !hasEntrypointOverride, !cmd.isEmpty {
                    result.append(contentsOf: cmd)
                }
            }
            return result.count > 0 ? result : nil
        }()

        guard let commandToRun = processArguments, commandToRun.count > 0 else {
            throw ContainerizationError(.invalidArgument, message: "Command/Entrypoint not specified for container process")
        }

        let defaultUser: ProcessConfiguration.User = {
            if let u = config?.user {
                return .raw(userString: u)
            }
            return .id(uid: 0, gid: 0)
        }()

        let (user, additionalGroups) = Parser.user(
            user: processFlags.user, uid: processFlags.uid,
            gid: processFlags.gid, defaultUser: defaultUser)

        return .init(
            executable: commandToRun.first!,
            arguments: [String](commandToRun.dropFirst()),
            environment: envvars,
            workingDirectory: workingDir,
            terminal: processFlags.tty,
            user: user,
            supplementalGroups: additionalGroups
        )
    }

    // MARK: Mounts

    public static let mountTypes = [
        "virtiofs",
        "bind",
        "tmpfs",
    ]

    public static let defaultDirectives = ["type": "virtiofs"]

    public static func tmpfsMounts(_ mounts: [String]) throws -> [Filesystem] {
        var result: [Filesystem] = []
        let mounts = mounts.dedupe()
        for tmpfs in mounts {
            let fs = Filesystem.tmpfs(destination: tmpfs, options: [])
            try validateMount(.filesystem(fs))
            result.append(fs)
        }
        return result
    }

    public static func mounts(_ rawMounts: [String]) throws -> [VolumeOrFilesystem] {
        var mounts: [VolumeOrFilesystem] = []
        let rawMounts = rawMounts.dedupe()
        for mount in rawMounts {
            let m = try Parser.mount(mount)
            try validateMount(m)
            mounts.append(m)
        }
        return mounts
    }

    public static func mount(_ mount: String) throws -> VolumeOrFilesystem {
        let parts = mount.split(separator: ",")
        if parts.count == 0 {
            throw ContainerizationError(.invalidArgument, message: "invalid mount format: \(mount)")
        }
        var directives = defaultDirectives
        for part in parts {
            let keyVal = part.split(separator: "=", maxSplits: 2)
            var key = String(keyVal[0])
            var skipValue = false
            switch key {
            case "type", "size", "mode":
                break
            case "source", "src":
                key = "source"
            case "destination", "dst", "target":
                key = "destination"
            case "readonly", "ro":
                key = "ro"
                skipValue = true
            default:
                throw ContainerizationError(.invalidArgument, message: "unknown directive \(key) when parsing mount \(mount)")
            }
            var value = ""
            if !skipValue {
                if keyVal.count != 2 {
                    throw ContainerizationError(.invalidArgument, message: "invalid directive format missing value \(part) in \(mount)")
                }
                value = String(keyVal[1])
            }
            directives[key] = value
        }

        var fs = Filesystem()
        var isVolume = false
        var volumeName = ""
        for (key, val) in directives {
            var val = val
            let type = directives["type"] ?? ""

            switch key {
            case "type":
                if val == "bind" {
                    val = "virtiofs"
                }
                switch val {
                case "virtiofs":
                    fs.type = Filesystem.FSType.virtiofs
                case "tmpfs":
                    fs.type = Filesystem.FSType.tmpfs
                case "volume":
                    // Volume type will be set later in source parsing when we create the actual volume filesystem
                    break
                default:
                    throw ContainerizationError(.invalidArgument, message: "unsupported mount type \(val)")
                }

            case "ro":
                fs.options.append("ro")
            case "size":
                if type != "tmpfs" {
                    throw ContainerizationError(.invalidArgument, message: "unsupported option size for \(type) mount")
                }
                var overflow: Bool
                var memory = try Parser.memoryString(val)
                (memory, overflow) = memory.multipliedReportingOverflow(by: 1024 * 1024)
                if overflow {
                    throw ContainerizationError(.invalidArgument, message: "overflow encountered when parsing memory string: \(val)")
                }
                let s = "size=\(memory)"
                fs.options.append(s)
            case "mode":
                if type != "tmpfs" {
                    throw ContainerizationError(.invalidArgument, message: "unsupported option mode for \(type) mount")
                }
                let s = "mode=\(val)"
                fs.options.append(s)
            case "source":
                switch type {
                case "virtiofs", "bind":
                    // For bind mounts, resolve both absolute and relative paths
                    let url = URL(filePath: val)
                    let absolutePath = url.absoluteURL.path

                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory) else {
                        throw ContainerizationError(.invalidArgument, message: "path '\(val)' does not exist")
                    }
                    guard isDirectory.boolValue else {
                        throw ContainerizationError(.invalidArgument, message: "path '\(val)' is not a directory")
                    }
                    fs.source = absolutePath
                case "volume":
                    // For volume mounts, validate as volume name
                    guard VolumeStorage.isValidVolumeName(val) else {
                        throw ContainerizationError(.invalidArgument, message: "Invalid volume name '\(val)': must match \(VolumeStorage.volumeNamePattern)")
                    }

                    // This is a named volume
                    isVolume = true
                    volumeName = val
                    fs.source = val
                case "tmpfs":
                    throw ContainerizationError(.invalidArgument, message: "cannot specify source for tmpfs mount")
                default:
                    throw ContainerizationError(.invalidArgument, message: "unknown mount type \(type)")
                }
            case "destination":
                fs.destination = val
            default:
                throw ContainerizationError(.invalidArgument, message: "unknown mount directive \(key)")
            }
        }

        guard isVolume else {
            return .filesystem(fs)
        }
        return .volume(
            ParsedVolume(
                name: volumeName,
                destination: fs.destination,
                options: fs.options
            ))
    }

    public static func volumes(_ rawVolumes: [String]) throws -> [VolumeOrFilesystem] {
        var mounts: [VolumeOrFilesystem] = []
        for volume in rawVolumes {
            let m = try Parser.volume(volume)
            try Parser.validateMount(m)
            mounts.append(m)
        }
        return mounts
    }

    public static func volume(_ volume: String) throws -> VolumeOrFilesystem {
        var vol = volume
        vol.trimLeft(char: ":")

        let parts = vol.split(separator: ":")
        switch parts.count {
        case 1:
            throw ContainerizationError(.invalidArgument, message: "anonymous volumes are not supported")
        case 2, 3:
            let src = String(parts[0])
            let dst = String(parts[1])

            // Check if it's an absolute directory path first
            guard src.hasPrefix("/") else {
                // Named volume - validate name syntax only
                guard VolumeStorage.isValidVolumeName(src) else {
                    throw ContainerizationError(.invalidArgument, message: "Invalid volume name '\(src)': must match \(VolumeStorage.volumeNamePattern)")
                }

                // This is a named volume
                let options = parts.count == 3 ? parts[2].split(separator: ",").map { String($0) } : []
                return .volume(
                    ParsedVolume(
                        name: src,
                        destination: dst,
                        options: options
                    ))
            }
            let url = URL(filePath: src)
            let absolutePath = url.absoluteURL.path

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory) else {
                throw ContainerizationError(.invalidArgument, message: "path '\(src)' does not exist")
            }

            // This is a filesystem mount
            var fs = Filesystem.virtiofs(
                source: URL(fileURLWithPath: absolutePath).absolutePath(),
                destination: dst,
                options: []
            )
            if parts.count == 3 {
                fs.options = parts[2].split(separator: ",").map { String($0) }
            }
            return .filesystem(fs)
        default:
            throw ContainerizationError(.invalidArgument, message: "invalid volume format \(volume)")
        }
    }

    public static func validMountType(_ type: String) -> Bool {
        mountTypes.contains(type)
    }

    public static func validateMount(_ mount: VolumeOrFilesystem) throws {
        switch mount {
        case .filesystem(let fs):
            if !fs.isTmpfs {
                if !fs.source.isAbsolutePath() {
                    throw ContainerizationError(
                        .invalidArgument, message: "\(fs.source) is not an absolute path on the host")
                }
                if !FileManager.default.fileExists(atPath: fs.source) {
                    throw ContainerizationError(.invalidArgument, message: "file path '\(fs.source)' does not exist")
                }
            }

            if fs.destination.isEmpty {
                throw ContainerizationError(.invalidArgument, message: "mount destination cannot be empty")
            }
        case .volume(let vol):
            if vol.destination.isEmpty {
                throw ContainerizationError(.invalidArgument, message: "volume destination cannot be empty")
            }
        // Volume name validation already done during parsing
        }
    }

    /// Parse --publish-port arguments into PublishPort objects
    /// The format of each argument is `[host-ip:]host-port:container-port[/protocol]`
    /// (e.g., "127.0.0.1:8080:80/tcp")
    ///
    /// - Parameter rawPublishPorts: Array of port arguments
    /// - Returns: Array of PublishPort objects
    /// - Throws: ContainerizationError if parsing fails
    public static func publishPorts(_ rawPublishPorts: [String]) throws -> [PublishPort] {
        var sockets: [PublishPort] = []

        // Process each raw port string
        for socket in rawPublishPorts {
            let parsedSocket = try Parser.publishPort(socket)
            sockets.append(parsedSocket)
        }
        return sockets
    }

    // Parse a single `--publish-port` argument into a `PublishPort`.
    public static func publishPort(_ portText: String) throws -> PublishPort {
        let protoSplit = portText.split(separator: "/")
        let proto: PublishProtocol
        let addressAndPortText: String
        switch protoSplit.count {
        case 1:
            addressAndPortText = String(protoSplit[0])
            proto = .tcp
        case 2:
            addressAndPortText = String(protoSplit[0])
            let protoText = String(protoSplit[1])
            guard let parsedProto = PublishProtocol(protoText) else {
                throw ContainerizationError(.invalidArgument, message: "invalid publish protocol: \(protoText)")
            }
            proto = parsedProto
        default:
            throw ContainerizationError(.invalidArgument, message: "invalid publish value: \(portText)")
        }

        let hostAddress: String
        let hostPortText: String
        let containerPortText: String
        let parts = addressAndPortText.split(separator: ":")
        switch parts.count {
        case 2:
            hostAddress = "0.0.0.0"
            hostPortText = String(parts[0])
            containerPortText = String(parts[1])
        case 3:
            hostAddress = String(parts[0])
            hostPortText = String(parts[1])
            containerPortText = String(parts[2])
        default:
            throw ContainerizationError(.invalidArgument, message: "invalid publish address: \(portText)")
        }

        guard let hostPort = Int(hostPortText) else {
            throw ContainerizationError(.invalidArgument, message: "invalid publish host port: \(hostPortText)")
        }

        guard let containerPort = Int(containerPortText) else {
            throw ContainerizationError(.invalidArgument, message: "invalid publish container port: \(containerPortText)")
        }

        return PublishPort(
            hostAddress: hostAddress,
            hostPort: hostPort,
            containerPort: containerPort,
            proto: proto
        )
    }

    /// Parse --publish-socket arguments into PublishSocket objects
    /// The format of each argument is `host_path:container_path`
    /// (e.g., "/tmp/docker.sock:/var/run/docker.sock")
    ///
    /// - Parameter rawPublishSockets: Array of socket arguments
    /// - Returns: Array of PublishSocket objects
    /// - Throws: ContainerizationError if parsing fails or a path is invalid
    public static func publishSockets(_ rawPublishSockets: [String]) throws -> [PublishSocket] {
        var sockets: [PublishSocket] = []

        // Process each raw socket string
        for socket in rawPublishSockets {
            let parsedSocket = try Parser.publishSocket(socket)
            sockets.append(parsedSocket)
        }
        return sockets
    }

    // Parse a single `--publish-socket`` argument into a `PublishSocket`.
    public static func publishSocket(_ socketText: String) throws -> PublishSocket {
        // Split by colon to two parts: [host_path, container_path]
        let parts = socketText.split(separator: ":")

        switch parts.count {
        case 2:
            // Extract host and container paths
            let hostPath = String(parts[0])
            let containerPath = String(parts[1])

            // Validate paths are not empty
            if hostPath.isEmpty {
                throw ContainerizationError(
                    .invalidArgument, message: "host socket path cannot be empty")
            }
            if containerPath.isEmpty {
                throw ContainerizationError(
                    .invalidArgument, message: "container socket path cannot be empty")
            }

            // Ensure container path must start with /
            if !containerPath.hasPrefix("/") {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "container socket path must be absolute: \(containerPath)")
            }

            // Convert host path to absolute path for consistency
            let hostURL = URL(fileURLWithPath: hostPath)
            let absoluteHostPath = hostURL.absoluteURL.path

            // Check if host socket already exists and might be in use
            if FileManager.default.fileExists(atPath: absoluteHostPath) {
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: absoluteHostPath)
                    if let fileType = attrs[.type] as? FileAttributeType, fileType == .typeSocket {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "host socket \(absoluteHostPath) already exists and may be in use")
                    }
                    // If it exists but is not a socket, we can remove it and create socket
                    try FileManager.default.removeItem(atPath: absoluteHostPath)
                } catch let error as ContainerizationError {
                    throw error
                } catch {
                    // For other file system errors, continue with creation
                }
            }

            // Create host directory if it doesn't exist
            let hostDir = hostURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: hostDir.path) {
                try FileManager.default.createDirectory(
                    at: hostDir, withIntermediateDirectories: true)
            }

            // Create and return PublishSocket object with validated paths
            return PublishSocket(
                containerPath: URL(fileURLWithPath: containerPath),
                hostPath: URL(fileURLWithPath: absoluteHostPath),
                permissions: nil
            )

        default:
            throw ContainerizationError(
                .invalidArgument,
                message:
                    "invalid publish-socket format \(socketText). Expected: host_path:container_path")
        }
    }

    // MARK: DNS

    public static func isValidDomainName(_ name: String) -> Bool {
        guard !name.isEmpty && name.count <= 255 else {
            return false
        }
        return name.components(separatedBy: ".").allSatisfy { Self.isValidDomainNameLabel($0) }
    }

    public static func isValidDomainNameLabel(_ label: String) -> Bool {
        guard !label.isEmpty && label.count <= 63 else {
            return false
        }
        let pattern = #/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/#
        return !label.ranges(of: pattern).isEmpty
    }

    // MARK: Miscellaneous

    public static func parseBool(string: String) -> Bool? {
        let lower = string.lowercased()
        switch lower {
        case "true", "t": return true
        case "false", "f": return false
        default: return nil
        }
    }
}
