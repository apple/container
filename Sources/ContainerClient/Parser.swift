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

import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation

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

    static func envFile(path: String) throws -> [String] {
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
                let keyVals = line.split(separator: "=")
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

    static func env(envList: [String]) -> [String] {
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

    static func labels(_ rawLabels: [String]) throws -> [String: String] {
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

    static func process(
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
            if let entrypoint = managementFlags.entryPoint, !entrypoint.isEmpty {
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

    static let mountTypes = [
        "virtiofs",
        "bind",
        "tmpfs",
    ]

    static let defaultDirectives = ["type": "virtiofs"]

    static func tmpfsMounts(_ mounts: [String]) throws -> [Filesystem] {
        var result: [Filesystem] = []
        let mounts = mounts.dedupe()
        for tmpfs in mounts {
            let fs = Filesystem.tmpfs(destination: tmpfs, options: [])
            try validateMount(fs)
            result.append(fs)
        }
        return result
    }

    static func mounts(_ rawMounts: [String]) throws -> [Filesystem] {
        var mounts: [Filesystem] = []
        let rawMounts = rawMounts.dedupe()
        for mount in rawMounts {
            let m = try Parser.mount(mount)
            try validateMount(m)
            mounts.append(m)
        }
        return mounts
    }

    static func mount(_ mount: String) throws -> Filesystem {
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
                let absPath = URL(filePath: val).absoluteURL.path
                switch type {
                case "virtiofs", "bind":
                    fs.source = absPath
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
        return fs
    }

    static func volumes(_ rawVolumes: [String]) throws -> [Filesystem] {
        var mounts: [Filesystem] = []
        for volume in rawVolumes {
            let m = try Parser.volume(volume)
            try Parser.validateMount(m)
            mounts.append(m)
        }
        return mounts
    }

    private static func volume(_ volume: String) throws -> Filesystem {
        var vol = volume
        vol.trimLeft(char: ":")

        let parts = vol.split(separator: ":")
        switch parts.count {
        case 1:
            throw ContainerizationError(.invalidArgument, message: "anonymous volumes are not supported")
        case 2, 3:
            // Bind / volume mounts.
            let src = String(parts[0])
            let dst = String(parts[1])

            let abs = URL(filePath: src).absoluteURL.path
            if !FileManager.default.fileExists(atPath: abs) {
                throw ContainerizationError(.invalidArgument, message: "named volumes are not supported")
            }

            var fs = Filesystem.virtiofs(
                source: URL(fileURLWithPath: src).absolutePath(),
                destination: dst,
                options: []
            )
            if parts.count == 3 {
                fs.options = parts[2].split(separator: ",").map { String($0) }
            }
            return fs
        default:
            throw ContainerizationError(.invalidArgument, message: "invalid volume format \(volume)")
        }
    }

    static func validMountType(_ type: String) -> Bool {
        mountTypes.contains(type)
    }

    static func validateMount(_ mount: Filesystem) throws {
        if !mount.isTmpfs {
            if !mount.source.isAbsolutePath() {
                throw ContainerizationError(
                    .invalidArgument, message: "\(mount.source) is not an absolute path on the host")
            }
            if !FileManager.default.fileExists(atPath: mount.source) {
                throw ContainerizationError(.invalidArgument, message: "file path '\(mount.source)' does not exist")
            }
        }

        if mount.destination.isEmpty {
            throw ContainerizationError(.invalidArgument, message: "mount destination cannot be empty")
        }
    }

    // Parse --publish-socket arguments into PublishSocket objects
    // Format: "host_path:container_path" (e.g., "/tmp/docker.sock:/var/run/docker.sock")
    //
    // - Parameter rawPublishSockets: Array of socket specifications
    // - Returns: Array of PublishSocket objects
    // - Throws: ContainerizationError if parsing fails
    static func publishSockets(_ rawPublishSockets: [String]) throws -> [PublishSocket] {
        var sockets: [PublishSocket] = []

        // Process each raw socket string
        for socket in rawPublishSockets {
            let parsedSocket = try Parser.publishSocket(socket)
            sockets.append(parsedSocket)
        }
        return sockets
    }

    // Parse a single --publish-socket argument and validate paths
    // Format: "host_path:container_path" -> PublishSocket
    private static func publishSocket(_ socket: String) throws -> PublishSocket {
        // Split by colon to two parts: [host_path, container_path]
        let parts = socket.split(separator: ":")

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
                    "invalid publish-socket format \(socket). Expected: host_path:container_path")
        }
    }
}
