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

import ContainerNetworkClient
import ContainerOS
import ContainerPersistence
import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import NIO
import NIOFoundationCompat
import SocketForwarder
import Synchronization
import SystemPackage

import struct ContainerizationOCI.Mount
import struct ContainerizationOCI.Process

/// An XPC service that manages the lifecycle of a VM-backed sandbox and the
/// containers running in it.
public actor RuntimeService {
    private let connection: xpc_connection_t
    private let root: URL
    private let interfaceStrategies: [NetworkInterfaceKey: InterfaceStrategy]
    /// The machine this service drives, once it has been bootstrapped.
    private var sandbox: (any Sandbox)?
    /// The containers in that machine, by identifier. A pod holds several and
    /// a standalone container holds one.
    private var containers: [String: ContainerInfo] = [:]
    /// The addresses a pod claimed, which every container placed in it shares.
    private var podAttachments: [Attachment] = []
    /// The ports published on those addresses, which are the pod's because the
    /// addresses are, and are forwarded once for all of its containers.
    private var podPublishedPorts: [PublishPort] = []
    private let monitor: ExitMonitor
    private let eventLoopGroup: any EventLoopGroup
    private var waiters: [String: ExitWaiter] = [:]
    private let lock: AsyncLock = AsyncLock()
    private let log: Logging.Logger
    private var state: State = .created
    private var processes: [String: ProcessInfo] = [:]
    private var socketForwarders: [SocketForwarderResult] = []
    private var networkSessions: [XPCClientSession] = []

    private static let sshAuthSocketGuestPath = "/var/host-services/ssh-auth.sock"
    private static let sshAuthSocketEnvVar = "SSH_AUTH_SOCK"

    class ExitWaiter {
        public var exitStatus: ExitStatus? = nil
        public var continuations: [CheckedContinuation<ExitStatus, Never>] = []

        public func wait(_ cc: CheckedContinuation<ExitStatus, Never>) {
            if let exitStatus = exitStatus {
                // `doExit` has already been called for this waiter
                cc.resume(returning: exitStatus)
                return
            }
            continuations.append(cc)
        }

        public func doExit(exitStatus: ExitStatus) {
            for cc in continuations {
                cc.resume(returning: exitStatus)
            }

            self.exitStatus = exitStatus
        }
    }

    private static func sshAuthSocketHostUrl(
        config: ContainerConfiguration,
        dynamicEnv: [String: String] = [:],
        log: Logger? = nil
    ) -> URL? {
        guard config.ssh else {
            return nil
        }

        guard let sshSocket = dynamicEnv[Self.sshAuthSocketEnvVar] else {
            log?.warning("ssh forwarding requested but no \(Self.sshAuthSocketEnvVar) found")
            return nil
        }

        return URL(fileURLWithPath: sshSocket)
    }

    public init(
        root: URL,
        interfaceStrategies: [NetworkInterfaceKey: InterfaceStrategy],
        eventLoopGroup: any EventLoopGroup,
        connection: xpc_connection_t,
        log: Logger
    ) {
        self.root = root
        self.interfaceStrategies = interfaceStrategies
        self.log = log
        self.monitor = ExitMonitor(log: log)
        self.eventLoopGroup = eventLoopGroup
        self.connection = connection
    }

    /// Returns an endpoint from an anonymous xpc connection.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - endpoint: An XPC endpoint that can be used to communicate
    ///     with the runtime service.
    @Sendable
    public func createEndpoint(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        let endpoint = xpc_endpoint_create(self.connection)
        let reply = message.reply()
        reply.set(key: RuntimeKeys.runtimeServiceEndpoint.rawValue, value: endpoint)
        return reply
    }

    /// Start the VM and the guest agent process for a container.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func bootstrap(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        // Create the bundle if it doesn't exist yet
        if !self.bundleExists(at: self.root) {
            try self.createBundle()
        }

        return try await self.lock.withLock { _ in
            // A machine that is not waiting to be brought up is running, and a
            // request for one that is running is a container joining it: what
            // the machine does not hold yet goes in, and the machine stays as
            // it is.
            guard await self.state == .created else {
                try await self.placeContainers(message)
                return message.reply()
            }

            let bundle = ContainerResource.Bundle(path: self.root)
            try bundle.createLogFile()

            // Every container runs in a pod, so every machine this service
            // drives is a pod's.
            guard bundle.isPod else {
                throw ContainerizationError(
                    .invalidState,
                    message: "a sandbox is bootstrapped from a pod, and \(self.root.path) holds none"
                )
            }
            return try await self.bootstrapPod(message, bundle: bundle)
        }
    }

    /// Start the container workload inside the virtual machine.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: A client identifier for the process.
    ///     - stdio: An array of file handles for standard input, output, and error.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func startProcess(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { lock in
            let id = try message.id()
            let containerInfo = try await self.addressedContainer(message)
            let containerId = containerInfo.id
            if id == containerId {
                try await self.startInitProcess(containerId, lock: lock)
                await self.setState(.running)
            } else {
                try await self.startExecProcess(processId: id, lock: lock)
            }
            return message.reply()
        }
    }

    /// Get statistics for the container.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: A client identifier for the process.
    ///     - stdio: An array of file handles for standard input, output, and error.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - statistics: JSON serialization of the `ContainerStats`.
    @Sendable
    public func statistics(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { lock in
            let containerInfo = try await self.addressedContainer(message)
            let sandbox = try await self.getSandbox()
            guard let stats = try await sandbox.statistics(containerIDs: [containerInfo.id], categories: .all).first else {
                throw ContainerizationError(
                    .notFound,
                    message: "no statistics for container \(containerInfo.id)"
                )
            }

            let containerStats = ContainerStats(
                id: stats.id,
                memoryUsageBytes: stats.memory?.usageBytes,
                memoryLimitBytes: stats.memory?.limitBytes,
                cpuUsageUsec: stats.cpu?.usageUsec,
                networkRxBytes: stats.networks?.reduce(0) { $0 + $1.receivedBytes },
                networkTxBytes: stats.networks?.reduce(0) { $0 + $1.transmittedBytes },
                blockReadBytes: stats.blockIO?.devices.reduce(0) { $0 + $1.readBytes },
                blockWriteBytes: stats.blockIO?.devices.reduce(0) { $0 + $1.writeBytes },
                numProcesses: stats.process?.current
            )

            let reply = message.reply()
            let data = try JSONEncoder().encode(containerStats)
            reply.set(key: RuntimeKeys.statistics.rawValue, value: data)
            return reply
        }
    }

    /// Shutdown the RuntimeService.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func shutdown(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { _ in
            switch await self.state {
            case .created, .stopped, .stopping:
                await self.setState(.shuttingDown)

            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot shutdown: container is not stopped"
                )
            }

            return message.reply()
        }
    }

    /// Create a process inside the virtual machine for the container.
    ///
    /// Use this procedure to run ad hoc processes in the virtual
    /// machine (`container exec`).
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: A client identifier for the process.
    ///     - processConfig: JSON serialization of the `ProcessConfiguration`
    ///       containing the process attributes.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func createProcess(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { [self] _ in
            switch await self.state {
            case .running, .booted:
                let id = try message.id()
                let config = try message.processConfig()
                let stdio = message.stdio()
                let container = try await self.addressedContainer(message)

                try await self.addNewProcess(id, in: container.id, config, stdio)

                try await self.initializeWaiters(for: id)
                do {
                    try await self.monitor.registerProcess(
                        id: id,
                        onExit: { id, exitStatus in
                            await self.releaseWaiters(for: id, status: exitStatus)

                            guard let process = await self.processes[id]?.process else {
                                throw ContainerizationError(
                                    .invalidState,
                                    message: "ProcessInfo missing for process \(id)"
                                )
                            }
                            try await process.delete()
                            try await self.setProcessState(id: id, state: .stopped)
                        }
                    )
                } catch {
                    await self.releaseWaiters(for: id, status: ExitStatus(exitCode: -1))
                    throw error
                }

                return message.reply()
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot exec: container is not running"
                )
            }
        }
    }

    /// Return the state for the sandbox and its containers.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - snapshot: The JSON serialization of the `SandboxSnapshot`
    ///     that contains the state information.
    @Sendable
    public func state(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        var status: RuntimeStatus = .unknown
        var networks: [Attachment] = []
        var snapshots: [ContainerSnapshot] = []

        switch state {
        case .created, .stopped, .booted, .shuttingDown:
            status = .stopped
        case .stopping:
            status = .stopping
        case .running:
            status = .running
            // The attachments belong to the machine, so any container in it
            // reports the same ones.
            networks = self.containers.values.first?.attachments ?? []
            snapshots = self.containers.values
                .sorted { $0.id < $1.id }
                .map {
                    ContainerSnapshot(
                        configuration: $0.config,
                        status: RuntimeStatus.running,
                        networks: $0.attachments
                    )
                }
        }

        let reply = message.reply()
        try reply.setState(
            .init(
                status: status,
                networks: networks,
                containers: snapshots
            )
        )
        return reply
    }

    /// Stop the container workload, any ad hoc processes, and the underlying
    /// virtual machine.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - stopOptions: JSON serialization of `ContainerStopOptions`
    ///       that modify stop behavior.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func stop(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        let stopOptions = try message.stopOptions()
        let signal = try Signal(stopOptions.signal ?? "SIGTERM")
        let timeout: Duration = .seconds(stopOptions.timeoutInSeconds)

        return try await self.lock.withLock { _ in
            switch await self.state {
            case .running, .booted:
                await self.setState(.stopping)

                let sandbox = try await self.getSandbox()
                // Every container in the machine is stopped before the machine
                // itself goes, so each is given its chance to end on its own.
                var exitStatuses: [String: ExitStatus] = [:]
                for ctr in await self.sortedContainers() {
                    exitStatuses[ctr.id] = try await self.gracefulStopContainer(
                        sandbox,
                        id: ctr.id,
                        signal: signal,
                        timeout: timeout
                    )
                }
                try await sandbox.stop()

                do {
                    if case .stopped = await self.state {
                        return message.reply()
                    }
                    for ctr in await self.sortedContainers() {
                        try await self.cleanUpContainer(containerInfo: ctr, exitStatus: exitStatuses[ctr.id])
                    }
                } catch {
                    self.log.error("failed to clean up container", metadata: ["error": "\(error)"])
                }
                await self.setState(.stopped)
            default:
                break
            }
            return message.reply()
        }
    }

    /// Signal a process running in the virtual machine.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: The process identifier.
    ///     - signal: The signal value.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    /// Stop the container a message is addressed to.
    ///
    /// The machine holds it and whatever else was put in it, and runs while any
    /// of them runs, so it goes down here only once the last one has stopped.
    /// A machine given a single container therefore goes down with it, which is
    /// what it did when a container had a machine to itself, and a machine
    /// holding several stays up for the rest.
    public func stopContainer(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        let container = try self.addressedContainer(message)
        let stopOptions = try message.stopOptions()
        let signal = try Signal(stopOptions.signal ?? "SIGTERM")
        let timeout: Duration = .seconds(stopOptions.timeoutInSeconds)

        return try await self.lock.withLock { _ in
            let sandbox = try await self.getSandbox()
            _ = try await self.gracefulStopContainer(
                sandbox,
                id: container.config.id,
                signal: signal,
                timeout: timeout
            )
            return message.reply()
        }
    }

    public func kill(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        let id = try message.id()
        let signal = try Signal(message.signal())

        try await self.lock.withLock { [self] _ in
            switch await self.state {
            case .running:
                // A process named for a container in the machine is that
                // container's init; anything else was started by an exec.
                guard await self.isContainer(id) else {
                    guard let processInfo = await self.processes[id] else {
                        throw ContainerizationError(.invalidState, message: "process \(id) does not exist")
                    }

                    guard let proc = processInfo.process else {
                        throw ContainerizationError(.invalidState, message: "process \(id) not started")
                    }
                    try await proc.kill(signal)
                    return
                }

                try await self.getSandbox().killContainer(id, signal: signal)
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot kill: container is not running"
                )
            }
        }

        // SIGKILL is guaranteed by the kernel to terminate the target, so block
        // until we observe the exit.
        if signal == .kill {
            _ = await withCheckedContinuation { cc in
                self.waitForExit(id: id, cont: cc)
            }
        }

        return message.reply()
    }

    /// Resize the terminal for a process.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: The process identifier.
    ///     - width: The terminal width.
    ///     - height: The terminal height.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func resize(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.trace("enter", metadata: ["func": "\(#function)"])
        defer { self.log.trace("exit", metadata: ["func": "\(#function)"]) }

        switch self.state {
        case .running:
            let id = try message.id()
            let width = message.uint64(key: RuntimeKeys.width.rawValue)
            let height = message.uint64(key: RuntimeKeys.height.rawValue)
            let size = Terminal.Size(width: UInt16(width), height: UInt16(height))

            if self.isContainer(id) {
                try await self.getSandbox().resizeContainer(id, to: size)
            } else {
                guard let processInfo = self.processes[id] else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "process \(id) does not exist"
                    )
                }

                guard let proc = processInfo.process else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "process \(id) not started"
                    )
                }

                try await proc.resize(to: size)
            }

            return message.reply()
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot resize: container is not running"
            )
        }
    }

    /// Wait for a process.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: The process identifier.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - exitCode: The exit code for the process.
    @Sendable
    public func wait(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard let id = message.string(key: RuntimeKeys.id.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "missing id in wait xpc message")
        }

        let exitStatus = await withCheckedContinuation { cc in
            self.waitForExit(id: id, cont: cc)
        }
        let reply = message.reply()
        reply.set(key: RuntimeKeys.exitCode.rawValue, value: Int64(exitStatus.exitCode))
        reply.set(key: RuntimeKeys.exitedAt.rawValue, value: exitStatus.exitedAt)
        return reply
    }

    /// Copy a file or directory from the host into the container.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - sourcePath: The host path to copy from.
    ///     - destinationPath: The container path to copy to.
    ///     - fileMode: The file permissions mode (UInt64).
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func copyIn(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.info("`copyIn` xpc handler")
        switch self.state {
        case .running, .booted:
            guard let source = message.string(key: RuntimeKeys.sourcePath.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no source path supplied for copyIn"
                )
            }
            guard let destination = message.string(key: RuntimeKeys.destinationPath.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no destination path supplied for copyIn"
                )
            }
            let mode = UInt32(message.uint64(key: RuntimeKeys.fileMode.rawValue))
            let createParents = message.bool(key: RuntimeKeys.createParents.rawValue)

            let ctr = try addressedContainer(message)
            try await self.getSandbox().copyIn(
                ctr.id,
                from: URL(fileURLWithPath: source),
                to: URL(fileURLWithPath: destination),
                mode: mode,
                createParents: createParents
            )

            return message.reply()
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot copyIn: container is not running"
            )
        }
    }

    /// Copy a file or directory from the container to the host.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - sourcePath: The container path to copy from.
    ///     - destinationPath: The host path to copy to.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func copyOut(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.info("`copyOut` xpc handler")
        switch self.state {
        case .running, .booted:
            guard let source = message.string(key: RuntimeKeys.sourcePath.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no source path supplied for copyOut"
                )
            }
            guard let destination = message.string(key: RuntimeKeys.destinationPath.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no destination path supplied for copyOut"
                )
            }

            let createParents = message.bool(key: RuntimeKeys.createParents.rawValue)

            let ctr = try addressedContainer(message)
            try await self.getSandbox().copyOut(
                ctr.id,
                from: URL(fileURLWithPath: source),
                to: URL(fileURLWithPath: destination),
                createParents: createParents
            )

            return message.reply()
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot copyOut: container is not running"
            )
        }
    }

    /// Snapshot the container's root filesystem.
    ///
    /// When the container is running, freeze/thaw around the copy for consistency.
    /// When it is not running, copy directly without freeze/thaw.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - imagePath: The path to the source filesystem image.
    ///     - destinationPath: The path where the snapshot will be written.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func snapshotDisk(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.info("`snapshotDisk` xpc handler")
        switch self.state {
        case .running, .booted:
            guard let imagePath = message.string(key: RuntimeKeys.imagePath.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no image path supplied for snapshotDisk"
                )
            }
            guard let destinationPath = message.string(key: RuntimeKeys.destinationPath.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no destination path supplied for snapshotDisk"
                )
            }

            let ctr = try addressedContainer(message)
            let sandbox = try getSandbox()
            let shouldFreeze = self.state == .running

            if shouldFreeze {
                try await sandbox.filesystemOperation(ctr.id, operation: .freeze, path: "/")
            }

            do {
                try FileManager.default.copyItem(atPath: imagePath, toPath: destinationPath)
            } catch {
                if shouldFreeze {
                    do {
                        try await sandbox.filesystemOperation(ctr.id, operation: .thaw, path: "/")
                    } catch {
                        self.log.error(
                            "failed to thaw filesystem after snapshotDisk error",
                            metadata: [
                                "error": "\(error)"
                            ])
                    }
                }
                throw error
            }

            if shouldFreeze {
                try await sandbox.filesystemOperation(ctr.id, operation: .thaw, path: "/")
            }

            return message.reply()
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot snapshot disk: container is not running"
            )
        }
    }

    /// Dial a vsock port on the virtual machine.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - port: The port number.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - fd: The file descriptor for the vsock.
    @Sendable
    public func dial(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        switch self.state {
        case .running, .booted:
            let port = message.uint64(key: RuntimeKeys.port.rawValue)
            guard port > 0 else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no vsock port supplied for dial"
                )
            }

            let fh = try await getSandbox().dialVsock(port: UInt32(port))

            let reply = message.reply()
            reply.set(key: RuntimeKeys.fd.rawValue, value: fh)
            return reply
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot dial: container is not running"
            )
        }
    }

    private func startInitProcess(_ id: String, lock: AsyncLock.Context) async throws {
        let info = try self.getContainer(id)
        let sandbox = try self.getSandbox()

        guard self.state == .booted || self.state == .running else {
            throw ContainerizationError(
                .invalidState,
                message: "container expected to be in booted state, got: \(self.state)"
            )
        }

        do {
            let io = info.io

            try await sandbox.startContainer(id)
            let waitFunc: ExitMonitor.WaitHandler = {
                let code = try await sandbox.waitContainer(id, timeoutInSeconds: nil)
                if let out = io.out {
                    try out.close()
                }
                if let err = io.err {
                    try err.close()
                }
                return code
            }
            try await self.monitor.track(id: id, waitingOn: waitFunc)
        } catch {
            try? await self.cleanUpContainer(containerInfo: info)
            self.setState(.stopped)
            throw error
        }
    }

    private func startExecProcess(processId id: String, lock: AsyncLock.Context) async throws {
        let sandbox = try self.getSandbox()
        guard let processInfo = self.processes[id] else {
            throw ContainerizationError(.notFound, message: "process with id \(id)")
        }

        let containerInfo = try self.getContainer(processInfo.containerId)
        let czConfig = try self.configureProcessConfig(
            config: processInfo.config,
            stdio: processInfo.io,
            containerConfig: containerInfo.config,
        )

        let process = try await sandbox.execInContainer(containerInfo.id, processID: id) { config in
            config = czConfig
        }
        try self.setUnderlyingProcess(id, process)

        try await process.start()

        let waitFunc: ExitMonitor.WaitHandler = {
            let code = try await process.wait()
            if let out = processInfo.io[1] {
                try self.closeHandle(out.fileDescriptor)
            }
            if let err = processInfo.io[2] {
                try self.closeHandle(err.fileDescriptor)
            }
            return code
        }
        try await self.monitor.track(id: id, waitingOn: waitFunc)
    }

    private func startSocketForwarders(attachment: Attachment, publishedPorts: [PublishPort]) async throws {
        guard !publishedPorts.isEmpty else {
            return
        }
        LocalNetworkPrivacy.triggerLocalNetworkPrivacyAlert()

        var forwarders: [SocketForwarderResult] = []
        guard !publishedPorts.hasOverlaps() else {
            throw ContainerizationError(.invalidArgument, message: "host ports for different publish port specs may not overlap")
        }

        try await withThrowingTaskGroup(of: SocketForwarderResult.self) { group in
            for publishedPort in publishedPorts {
                for index in 0..<publishedPort.count {
                    let proxyAddress = try SocketAddress(ipAddress: publishedPort.hostAddress.description, port: Int(publishedPort.hostPort + index))
                    let containerIPAddress: String
                    switch publishedPort.hostAddress {
                    case .v4(_):
                        containerIPAddress = attachment.ipv4Address.address.description
                    case .v6(_):
                        guard let ipv6Address = attachment.ipv6Address else {
                            throw ContainerizationError(.invalidState, message: "cannot configure IPv6 port forwarding for container with unknown IPv6 address")
                        }
                        containerIPAddress = ipv6Address.address.description
                    }
                    let serverAddress = try SocketAddress(ipAddress: containerIPAddress, port: Int(publishedPort.containerPort + index))
                    log.info(
                        "creating forwarder for",
                        metadata: [
                            "proxy": "\(proxyAddress)",
                            "server": "\(serverAddress)",
                            "protocol": "\(publishedPort.proto)",
                        ])
                    group.addTask {
                        let forwarder: SocketForwarder
                        switch publishedPort.proto {
                        case .tcp:
                            forwarder = try TCPForwarder(
                                proxyAddress: proxyAddress,
                                serverAddress: serverAddress,
                                eventLoopGroup: self.eventLoopGroup,
                                log: self.log
                            )
                        case .udp:
                            forwarder = try UDPForwarder(
                                proxyAddress: proxyAddress,
                                serverAddress: serverAddress,
                                eventLoopGroup: self.eventLoopGroup,
                                log: self.log
                            )
                        }
                        do {
                            return try await forwarder.run().get()
                        } catch let error as IOError where error.errnoCode == EACCES {
                            if let port = proxyAddress.port, port < 1024 {
                                throw ContainerizationError(
                                    .invalidArgument,
                                    message: "Permission denied while binding to host port \(port). Binding to ports below 1024 requires root privileges."
                                )
                            }
                            throw error
                        }
                    }
                }
            }
            for try await result in group {
                forwarders.append(result)
            }
        }

        self.socketForwarders = forwarders
    }

    private func stopSocketForwarders() async {
        log.info("closing forwarders")
        for forwarder in self.socketForwarders {
            forwarder.close()
            try? await forwarder.wait()
        }
        log.info("closed forwarders")
    }

    private func onContainerExit(id: String, exitStatus: ExitStatus) async throws {
        self.log.info("init process exited", metadata: ["id": "\(id)", "status": "\(exitStatus)"])

        try await self.lock.withLock { [self] _ in
            let ctrInfo = try await getContainer(id)

            switch await self.state {
            case .stopped, .stopping:
                return
            default:
                break
            }

            do {
                try await cleanUpContainer(containerInfo: ctrInfo, exitStatus: exitStatus)
            } catch {
                self.log.error("failed to clean up container", metadata: ["error": "\(error)"])
            }

            // A pod's machine is its sandbox, which outlives the containers
            // that come and go in it: it holds the addresses and namespaces
            // they share and is taken down when the pod is, not when a
            // container in it leaves. A single container's machine is the
            // container's own, so it stops with the last thing in it.
            // https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto
            let sandbox = try await self.getSandbox()
            guard !(sandbox is LinuxPod) else {
                return
            }
            guard await self.containers.isEmpty else {
                return
            }
            try? await sandbox.stop()
            await setState(.stopped)
        }
    }

    private nonisolated func getDefaultNameservers(from attachments: [Attachment]) -> [String] {
        for attachment in attachments {
            return [attachment.ipv4Gateway.description]
        }
        return []
    }

    /// The init process a container starts with, which is the same whether the
    /// container has a machine to itself or shares one with a pod's others.
    private static func configureInitialProcess(
        process czProcess: inout LinuxProcessConfiguration,
        config: ContainerConfiguration,
    ) throws {
        let process = config.initProcess

        czProcess.arguments = [process.executable] + process.arguments
        czProcess.environmentVariables = process.environment

        if config.ssh {
            if !czProcess.environmentVariables.contains(where: { $0.starts(with: "\(Self.sshAuthSocketEnvVar)=") }) {
                czProcess.environmentVariables.append("\(Self.sshAuthSocketEnvVar)=\(Self.sshAuthSocketGuestPath)")
            }
        }

        czProcess.terminal = process.terminal
        czProcess.workingDirectory = process.workingDirectory
        try czProcess.rlimits = process.rlimits.map {
            LinuxRLimit(
                kind: try LinuxRLimit.Kind($0.limit),
                hard: $0.hard,
                soft: $0.soft
            )
        }
        czProcess.capabilities = try Self.effectiveCapabilities(
            capAdd: config.capAdd,
            capDrop: config.capDrop
        )
        switch process.user {
        case .raw(let name):
            czProcess.user = .init(
                uid: 0,
                gid: 0,
                umask: nil,
                additionalGids: process.supplementalGroups,
                username: name
            )
        case .id(let uid, let gid):
            czProcess.user = .init(
                uid: uid,
                gid: gid,
                umask: nil,
                additionalGids: process.supplementalGroups,
                username: ""
            )
        }
    }

    /// The sockets a container asks for: those it is given, those it publishes,
    /// and the host's ssh agent when it asked for one.
    private static func sockets(
        config: ContainerConfiguration,
        dynamicEnv: [String: String],
        log: Logger?
    ) throws -> (sockets: [UnixSocketConfiguration], mounts: [Filesystem]) {
        var sockets: [UnixSocketConfiguration] = []
        var mounts: [Filesystem] = []

        for mount in config.mounts {
            if try mount.isSocket() {
                let attrs = try? FileManager.default.attributesOfItem(atPath: mount.source)
                let permissions = (attrs?[.posixPermissions] as? NSNumber)
                    .map { FilePermissions(rawValue: mode_t($0.intValue)) }
                sockets.append(
                    UnixSocketConfiguration(
                        source: URL(filePath: mount.source),
                        destination: URL(filePath: mount.destination),
                        permissions: permissions,
                        direction: .into,
                    ))
            } else {
                mounts.append(mount)
            }
        }

        for publishedSocket in config.publishedSockets {
            // UnixSocketConfiguration (Containerization) takes URL; convert from FilePath at the boundary.
            sockets.append(
                UnixSocketConfiguration(
                    source: URL(filePath: publishedSocket.containerPath.string),
                    destination: URL(filePath: publishedSocket.hostPath.string),
                    permissions: publishedSocket.permissions,
                    direction: .outOf
                ))
        }

        if let socketUrl = Self.sshAuthSocketHostUrl(config: config, dynamicEnv: dynamicEnv, log: log) {
            let socketPath = socketUrl.path(percentEncoded: false)
            let attrs = try? FileManager.default.attributesOfItem(atPath: socketPath)
            let permissions = (attrs?[.posixPermissions] as? NSNumber)
                .map { FilePermissions(rawValue: mode_t($0.intValue)) }
            sockets.append(
                UnixSocketConfiguration(
                    source: socketUrl,
                    destination: URL(fileURLWithPath: Self.sshAuthSocketGuestPath),
                    permissions: permissions,
                    direction: .into,
                ))
        }

        return (sockets, mounts)
    }

    /// The hostname a container reports, taken from the name its network knows
    /// it by, up to the first dot.
    /// The name the sandbox answers to, taken from the first network it
    /// attaches to and falling back to its own id.
    private static func hostname(networks: [AttachmentConfiguration], id: String) -> String {
        let hostnameSource = networks.first?.options.hostname ?? id
        return
            hostnameSource.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0) } ?? id
    }

    /// Configure a container that shares a pod's machine.
    ///
    /// The machine's processors, memory, swap, addresses and boot log are the
    /// pod's, so what is set here is the container's alone: what it runs, what
    /// it can see, and the limits it holds itself to within the pod's.
    private static func configurePodContainer(
        czConfig: inout LinuxPod.ContainerConfiguration,
        config: ContainerConfiguration,
        dynamicEnv: [String: String] = [:],
        log: Logger? = nil,
    ) throws {
        // A container in a pod draws on the machine's processors and memory
        // unless it was given a limit of its own.
        czConfig.cpus = config.resources.cpus
        czConfig.memoryInBytes = config.resources.memoryInBytes
        czConfig.swapInBytes = config.resources.swapInBytes

        czConfig.useInit = config.useInit

        // nil leaves the library's own default set in place.
        if let maskedPaths = config.maskedPaths {
            czConfig.maskedPaths = maskedPaths
        }
        if let readonlyPaths = config.readonlyPaths {
            czConfig.readonlyPaths = readonlyPaths
        }

        if let shmSize = config.shmSize {
            for i in czConfig.mounts.indices {
                if czConfig.mounts[i].destination == "/dev/shm" {
                    czConfig.mounts[i].options.removeAll { $0.hasPrefix("size=") }
                    czConfig.mounts[i].options.append("size=\(shmSize)")
                }
            }
        }

        let (sockets, mounts) = try Self.sockets(config: config, dynamicEnv: dynamicEnv, log: log)
        czConfig.sockets.append(contentsOf: sockets)
        czConfig.mounts.append(contentsOf: mounts.map { $0.asMount })

        // The hostname, the resolver and the hosts file are the sandbox's: the
        // runtime interface carries all three on the pod and gives a container
        // none of its own, so the pod holds them and its containers inherit
        // them. The library lets a container override each one; a container
        // here asks for none, so the pod's stand.
        // https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1/api.proto

        try Self.configureInitialProcess(process: &czConfig.process, config: config)
    }

    private nonisolated func configureProcessConfig(config: ProcessConfiguration, stdio: [FileHandle?], containerConfig: ContainerConfiguration)
        throws -> LinuxProcessConfiguration
    {
        var proc = LinuxProcessConfiguration()
        proc.stdin = stdio[0]
        proc.stdout = stdio[1]
        proc.stderr = stdio[2]

        proc.arguments = [config.executable] + config.arguments
        proc.environmentVariables = config.environment

        if containerConfig.ssh {
            if !proc.environmentVariables.contains(where: { $0.starts(with: "\(Self.sshAuthSocketEnvVar)=") }) {
                proc.environmentVariables.append("\(Self.sshAuthSocketEnvVar)=\(Self.sshAuthSocketGuestPath)")
            }
        }

        proc.terminal = config.terminal
        proc.workingDirectory = config.workingDirectory
        try proc.rlimits = config.rlimits.map {
            LinuxRLimit(
                kind: try LinuxRLimit.Kind($0.limit),
                hard: $0.hard,
                soft: $0.soft
            )
        }
        proc.capabilities = try Self.effectiveCapabilities(
            capAdd: containerConfig.capAdd,
            capDrop: containerConfig.capDrop
        )
        switch config.user {
        case .raw(let name):
            proc.user = .init(
                uid: 0,
                gid: 0,
                umask: nil,
                additionalGids: config.supplementalGroups,
                username: name
            )
        case .id(let uid, let gid):
            proc.user = .init(
                uid: uid,
                gid: gid,
                umask: nil,
                additionalGids: config.supplementalGroups,
                username: ""
            )
        }

        return proc
    }

    /// Compute effective Linux capabilities from the OCI default set, capAdd, and capDrop.
    /// Steps are processed in order, so later steps override earlier ones:
    /// 1. If "ALL" in capDrop, start empty; otherwise start from OCI defaults.
    /// 2. If "ALL" in capAdd, replace with all caps (overriding step 1); otherwise add individual caps.
    /// 3. Remove individual capDrop entries (skipping "ALL" sentinel).
    private static func effectiveCapabilities(capAdd: [String], capDrop: [String]) throws -> Containerization.LinuxCapabilities {
        // Step 1: Determine base set
        var caps: Set<CapabilityName>
        if capDrop.contains("ALL") {
            caps = []
        } else {
            caps = Set(Containerization.LinuxCapabilities.defaultOCICapabilities.effective)
        }

        // Step 2: Process adds
        if capAdd.contains("ALL") {
            caps = Set(CapabilityName.allCases)
        } else {
            for name in capAdd {
                caps.insert(try CapabilityName(rawValue: name))
            }
        }

        // Step 3: Remove individual drops (skip "ALL" sentinel)
        for name in capDrop where name != "ALL" {
            caps.remove(try CapabilityName(rawValue: name))
        }

        return Containerization.LinuxCapabilities(capabilities: Array(caps))
    }

    private nonisolated func closeHandle(_ handle: Int32) throws {
        guard close(handle) == 0 else {
            guard let errCode = POSIXErrorCode(rawValue: errno) else {
                fatalError("failed to convert errno to POSIXErrorCode")
            }
            throw POSIXError(errCode)
        }
    }

    /// Run the machine a pod's containers share, with those containers in it.
    ///
    /// The pod's own bundle carries the machine: its kernel, its initial
    /// filesystem, and the size, networks and name resolution its containers
    /// draw on. The containers keep bundles of their own, named in the request,
    /// and go in on the way to a machine that runs holding them.
    ///
    private func bootstrapPod(_ message: XPCMessage, bundle: ContainerResource.Bundle) async throws -> XPCMessage {
        let config = try bundle.podConfiguration
        let kernel = try self.kernelWithDefaultArgs(bundle.kernel)
        let vmm = VZVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: bundle.initialFilesystem.asMount,
            rosetta: config.rosetta,
            logger: self.log
        )

        let (sessions, attachments, interfaces) = try await self.allocateNetworks(
            config.networks,
            infos: try message.networkBootstrapInfos()
        )

        // Dynamically configure the DNS nameserver from a network if no explicit
        // configuration. The network belongs to the pod, so the resolver derived
        // from it does too, the way it was derived from the machine's attachments
        // when the machine held the network for one container.
        var nameservers = config.dns?.nameservers ?? []
        if nameservers.isEmpty {
            nameservers = self.getDefaultNameservers(from: attachments)
        }

        // One swap area serves the whole pod, which is what makes the pool its
        // containers reclaim to a shared one.
        let swapLayer = try config.resources.swapInBytes.map {
            try bundle.createSwapDevice(size: $0).asMount
        }

        let pod = try LinuxPod(config.id, vmm: vmm, logger: self.log) { podConfig in
            podConfig.cpus = config.resources.cpus
            podConfig.memoryInBytes = config.resources.memoryInBytes
            // The machine is built larger than the pod by what the guest agent
            // takes, so what the pod was given is what its containers have. A
            // caller sizing the machine itself asks for none of that overhead
            // and gets the size it named.
            podConfig.cpuOverhead = config.resources.cpuOverhead
            podConfig.swapLayer = swapLayer
            podConfig.interfaces = interfaces
            podConfig.virtualization = config.virtualization
            podConfig.shareProcessNamespace = config.shareProcessNamespace
            podConfig.hostname = config.hostname ?? Self.hostname(networks: config.networks, id: config.id)
            // The hosts file names the pod at its own address so its containers
            // reach the name they answer to, and it is written once for the pod
            // the way the resolver and the hostname are.
            var hostsEntries = [Hosts.Entry.localHostIPV4()]
            if let primary = attachments.first {
                hostsEntries.append(
                    Hosts.Entry(
                        ipAddress: primary.ipv4Address.address.description,
                        hostnames: [podConfig.hostname ?? config.id],
                    ))
            }
            podConfig.hosts = Hosts(entries: hostsEntries)
            // The runtime asks for these two of every machine it boots; they
            // stand alongside whatever the pod was given.
            var sysctls = config.sysctls
            sysctls["vm.overcommit_memory"] = "1"
            sysctls["vm.max_map_count"] = "262144"
            podConfig.sysctl = sysctls
            if !nameservers.isEmpty {
                podConfig.dns = DNS(
                    nameservers: nameservers,
                    domain: config.dns?.domain,
                    searchDomains: config.dns?.searchDomains ?? [],
                    options: config.dns?.options ?? []
                )
            }
            podConfig.bootLog = BootLog.file(path: bundle.bootlog, append: true)
        }

        self.setSandbox(pod)
        self.setNetworkSessions(sessions)
        self.podAttachments = attachments
        self.podPublishedPorts = config.publishedPorts

        try await self.placeContainers(message)

        try await pod.create()
        // The pod holds one address for every container in it, so the ports
        // published on it are the pod's and are forwarded once. Forwarding each
        // container's separately would let two of them claim one host port,
        // which the overlap check cannot see when it is asked about one
        // container at a time.
        if let primary = attachments.first {
            try await self.startSocketForwarders(attachment: primary, publishedPorts: config.publishedPorts)
        }
        self.setState(.booted)

        return message.reply()
    }

    /// Put the containers a request names in the sandbox.
    ///
    /// Each brings its own bundle, holding its configuration and its root
    /// filesystem, and takes the machine's processors, memory, swap and
    /// addresses as they are. One already in the machine stays as it is, so a
    /// request naming every container the pod holds puts in what is missing and
    /// leaves the rest alone.
    ///
    /// The standard streams belong to the one container whose start the request
    /// is; the others are placed with none and are given theirs when they are
    /// started in turn.
    private func placeContainers(_ message: XPCMessage) async throws {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard let pathsData = message.dataNoCopy(key: RuntimeKeys.bundlePaths.rawValue) else {
            return
        }
        let paths = try JSONDecoder().decode([String].self, from: pathsData)
        let stdioFor = message.string(key: RuntimeKeys.containerId.rawValue)

        for path in paths {
            try await self.placeContainer(
                at: path,
                stdio: URL(filePath: path).lastPathComponent == stdioFor ? message.stdio() : [nil, nil, nil],
                dynamicEnv: try message.dynamicEnv()
            )
        }
    }

    private func placeContainer(at path: String, stdio: [FileHandle?], dynamicEnv: [String: String]) async throws {
        let sandbox = try self.getSandbox()
        guard let pod = sandbox as? LinuxPod else {
            throw ContainerizationError(
                .invalidState,
                message: "the sandbox holds a single container and takes no others"
            )
        }

        // A container the machine already holds is one this request has nothing
        // to do for.
        guard !self.isContainer(URL(filePath: path).lastPathComponent) else {
            return
        }

        do {
            // A container placed in a pod has no machine of its own to build
            // its bundle, so the pod's machine builds it on the way in.
            let root = URL(filePath: path)
            if !self.bundleExists(at: root) {
                try self.createBundle(at: root)
            }

            let bundle = ContainerResource.Bundle(path: root)
            try bundle.createLogFile()
            let config = try bundle.configuration
            let containerLog = try FileHandle(forWritingTo: bundle.containerLog)
            let stdout = {
                if let h = stdio[1] {
                    return MultiWriter(handles: [h, containerLog])
                }
                return MultiWriter(handles: [containerLog])
            }()
            let stderr: MultiWriter? = {
                if !config.initProcess.terminal {
                    if let h = stdio[2] {
                        return MultiWriter(handles: [h, containerLog])
                    }
                    return MultiWriter(handles: [containerLog])
                }
                return nil
            }()
            let stdin = stdio[0] ?? nil

            let rootfs = try bundle.containerRootfs.asMount
            let attachments = self.podAttachments

            try await pod.addContainer(config.id, rootfs: rootfs) { czConfig in
                try Self.configurePodContainer(
                    czConfig: &czConfig,
                    config: config,
                    dynamicEnv: dynamicEnv,
                    log: self.log
                )
                czConfig.process.stdout = stdout
                czConfig.process.stderr = stderr
                czConfig.process.stdin = stdin
            }

            self.setContainer(
                ContainerInfo(
                    config: config,
                    attachments: attachments,
                    bundle: bundle,
                    io: (in: stdin, out: stdout, err: stderr)
                )
            )

            // What waits on the container waits from the moment it is in the
            // machine, so a container that boots with the machine and one that
            // joins a machine already running are both waited on the same way.
            try self.initializeWaiters(for: config.id)
            try await self.monitor.registerProcess(id: config.id, onExit: self.onContainerExit)
        }
    }

    /// Hold the running machine to a memory size, which its containers share.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - memoryInBytes: The size to hold the machine to.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func updateResources(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        let bytes = message.uint64(key: RuntimeKeys.memoryInBytes.rawValue)
        guard bytes > 0 else {
            throw ContainerizationError(.invalidArgument, message: "a memory size is required")
        }
        try await self.getSandbox().setTargetMemorySize(bytes)
        return message.reply()
    }

    /// Kernel arguments applied unless the caller already supplied the same
    /// key, so a custom kernel can override them (e.g. lsm=...,bpf).
    private func kernelWithDefaultArgs(_ kernel: Kernel) -> Kernel {
        var kernel = kernel
        let defaultKernelArgs: KeyValuePairs = [
            "oops": "panic",
            "lsm": "lockdown,capability,landlock,yama,apparmor",
        ]
        for (key, value) in defaultKernelArgs {
            guard !kernel.commandLine.kernelArgs.contains(where: { $0.hasPrefix("\(key)=") }) else {
                continue
            }
            kernel.commandLine.kernelArgs.append("\(key)=\(value)")
        }
        return kernel
    }

    /// Claim an address on each of the sandbox's networks.
    ///
    /// The attachments belong to the machine, which every container in it
    /// shares, since a container in a sandbox is given no network namespace of
    /// its own.
    private func allocateNetworks(
        _ networks: [AttachmentConfiguration],
        infos: [NetworkBootstrapInfo]
    ) async throws -> (sessions: [XPCClientSession], attachments: [Attachment], interfaces: [Interface]) {
        var sessions: [XPCClientSession] = []
        var attachments: [Attachment] = []
        var interfaces: [Interface] = []
        do {
            for (index, info) in infos.enumerated() {
                let attachmentConfig = networks[index]
                let client = ContainerNetworkClient.NetworkClient(id: attachmentConfig.network, plugin: info.plugin)
                let session = client.connect()
                sessions.append(session)
                var (attachment, additionalData) = try await client.allocate(
                    hostname: attachmentConfig.options.hostname,
                    macAddress: attachmentConfig.options.macAddress,
                    on: session
                )
                if let mtu = attachmentConfig.options.mtu {
                    attachment = Attachment(
                        network: attachment.network,
                        hostname: attachment.hostname,
                        ipv4Address: attachment.ipv4Address,
                        ipv4Gateway: attachment.ipv4Gateway,
                        ipv6Address: attachment.ipv6Address,
                        macAddress: attachment.macAddress,
                        mtu: mtu,
                        variant: attachment.variant
                    )
                }
                guard let iStrategy = self.interfaceStrategies[NetworkInterfaceKey(plugin: info.plugin, variant: attachment.variant)] else {
                    throw ContainerizationError(
                        .internalError,
                        message: "no available interface strategy for network \(attachment.network), plugin=\(info.plugin) variant=\(attachment.variant ?? "nil")")
                }
                let interface = try iStrategy.toInterface(
                    attachment: attachment,
                    interfaceIndex: index,
                    additionalData: additionalData
                )
                attachments.append(attachment)
                interfaces.append(interface)
            }
        } catch {
            for session in sessions { session.close() }
            throw error
        }
        return (sessions, attachments, interfaces)
    }

    /// The machine this service drives.
    private func getSandbox() throws -> any Sandbox {
        guard let sandbox else {
            throw ContainerizationError(
                .invalidState,
                message: "no sandbox found"
            )
        }
        return sandbox
    }

    /// The machine's containers in a settled order, so that what is done to
    /// each of them in turn happens the same way every time.
    private func sortedContainers() -> [ContainerInfo] {
        self.containers.values.sorted { $0.id < $1.id }
    }

    /// Whether a name is one of the machine's containers, which is what tells
    /// a container's init process apart from a process an exec started.
    private func isContainer(_ id: String) -> Bool {
        self.containers[id] != nil
    }

    /// A container in the machine, by name.
    private func getContainer(_ id: String) throws -> ContainerInfo {
        guard let container = self.containers[id] else {
            throw ContainerizationError(
                .notFound,
                message: "container \(id) not found in sandbox"
            )
        }
        return container
    }

    /// The container a message is addressed to.
    ///
    /// A request for a container names it, whatever else the machine holds, so
    /// that a machine holding one is answered the same way as a machine holding
    /// several and no request means "the only one here".
    private func addressedContainer(_ message: XPCMessage) throws -> ContainerInfo {
        guard let id = message.string(key: RuntimeKeys.containerId.rawValue), !id.isEmpty else {
            throw ContainerizationError(
                .invalidArgument,
                message: "the request names no container to act on"
            )
        }
        return try getContainer(id)
    }

    /// Stop one container in the sandbox and wait for it, then leave.
    ///
    /// The machine stays up, since the sandbox's other containers are still in
    /// it. Powering it off is the sandbox's own stop.
    private func gracefulStopContainer(
        _ sandbox: any Sandbox,
        id: String,
        signal: Signal,
        timeout: Duration
    ) async throws -> ExitStatus {
        // Try and gracefully shut down the process. Even if this succeeds we need to power off
        // the vm, but we should try this first always.
        var code = ExitStatus(exitCode: 255)
        do {
            code = try await withThrowingTaskGroup(of: ExitStatus.self) { group in
                group.addTask {
                    try await sandbox.waitContainer(id, timeoutInSeconds: nil)
                }
                group.addTask {
                    try await sandbox.killContainer(id, signal: signal)
                    try await Task.sleep(for: timeout)
                    try await sandbox.killContainer(id, signal: .kill)

                    return ExitStatus(exitCode: 137)
                }
                guard let code = try await group.next() else {
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to get exit code from gracefully stopping container"
                    )
                }
                group.cancelAll()

                return code
            }
        } catch {
            self.log.error("graceful stop failed; forcing vm shutdown", metadata: ["error": "\(error)"])
        }

        return code
    }

    private func cleanUpContainer(containerInfo: ContainerInfo, exitStatus: ExitStatus? = nil) async throws {
        let id = containerInfo.id

        do {
            try await self.getSandbox().stopContainer(id)
        } catch {
            self.log.error("failed to stop container during cleanup", metadata: ["error": "\(error)"])
        }

        // The machine keeps a stopped container's place until it is given
        // back. The registry below forgets the name, so the machine must give
        // it up too, or the next placement under it is refused against a
        // place nothing holds.
        do {
            try await self.getSandbox().removeContainer(id)
        } catch {
            self.log.error("failed to remove container during cleanup", metadata: ["error": "\(error)"])
        }

        self.containers.removeValue(forKey: id)
        self.processes.removeValue(forKey: id)
        await self.monitor.stopTracking(id: id)

        // The forwarders and the network sessions are the machine's, which the
        // sandbox's containers share, so they are given up once the last of
        // them is gone.
        if self.containers.isEmpty {
            await self.stopSocketForwarders()

            for session in networkSessions { session.close() }
            networkSessions = []
        }

        let status = exitStatus ?? ExitStatus(exitCode: 255)
        self.releaseWaiters(for: id, status: status)
        // The waiter's name is given back with the container's: whoever was
        // waiting has been answered, and the next container under this name
        // registers a waiter of its own.
        self.waiters.removeValue(forKey: id)
    }
}

extension XPCMessage {
    fileprivate func signal() throws -> String {
        guard let signal = self.string(key: RuntimeKeys.signal.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "missing signal in xpc message")
        }
        return signal
    }

    fileprivate func stopOptions() throws -> ContainerStopOptions {
        guard let data = self.dataNoCopy(key: RuntimeKeys.stopOptions.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "empty StopOptions")
        }
        return try JSONDecoder().decode(ContainerStopOptions.self, from: data)
    }

    fileprivate func setState(_ state: SandboxSnapshot) throws {
        let data = try JSONEncoder().encode(state)
        self.set(key: RuntimeKeys.snapshot.rawValue, value: data)
    }

    fileprivate func stdio() -> [FileHandle?] {
        var handles = [FileHandle?](repeating: nil, count: 3)
        if let stdin = self.fileHandle(key: RuntimeKeys.stdin.rawValue) {
            handles[0] = stdin
        }
        if let stdout = self.fileHandle(key: RuntimeKeys.stdout.rawValue) {
            handles[1] = stdout
        }
        if let stderr = self.fileHandle(key: RuntimeKeys.stderr.rawValue) {
            handles[2] = stderr
        }
        return handles
    }

    fileprivate func setFileHandle(_ handle: FileHandle) {
        self.set(key: RuntimeKeys.fd.rawValue, value: handle)
    }

    fileprivate func processConfig() throws -> ProcessConfiguration {
        guard let data = self.dataNoCopy(key: RuntimeKeys.processConfig.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "empty process configuration")
        }
        return try JSONDecoder().decode(ProcessConfiguration.self, from: data)
    }

    fileprivate func dynamicEnv() throws -> [String: String] {
        let data = self.dataNoCopy(key: RuntimeKeys.dynamicEnv.rawValue)
        let dynamicEnv = try data.map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        return dynamicEnv
    }

}

extension ContainerResource.Bundle {
    /// Create the raw block file backing the container's swap area.
    ///
    /// It carries no filesystem: the guest agent writes the swap header to the
    /// device and enables it. The file is sparse, so it costs the host only the
    /// pages the guest has actually swapped out, and gives them back on
    /// discard. A swap area held in a file has to be free of holes, since the
    /// kernel walks its extents; the guest reaches this one as a block device,
    /// which the kernel takes as a single extent without consulting the host's
    /// layout. https://github.com/torvalds/linux/blob/master/mm/swapfile.c
    /// The area holds nothing that outlives the container, so it is made afresh
    /// with every bootstrap and the host is told not to synchronize it.
    func createSwapDevice(size: UInt64) throws -> Filesystem {
        let path = self.containerSwapBlock
        guard FileManager.default.createFile(atPath: path.path, contents: nil) else {
            throw ContainerizationError(
                .internalError, message: "failed to create swap device at \(path.path)")
        }
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
        return .block(
            format: Swap.mountType,
            source: path.path,
            destination: "",
            options: [],
            sync: .nosync
        )
    }

    func createLogFile() throws {
        // Create the log file we'll write stdio to.
        // O_TRUNC resolves a log delay issue on restarted containers by force-updating internal state
        let fd = Darwin.open(self.containerLog.path, O_CREAT | O_RDONLY | O_TRUNC, 0o644)
        guard fd > 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        close(fd)
    }
}

extension Filesystem {
    var asMount: Containerization.Mount {
        switch self.type {
        case .tmpfs:
            return .any(
                type: "tmpfs",
                source: self.source,
                destination: self.destination,
                options: self.options
            )
        case .virtiofs:
            return .share(
                source: self.source,
                destination: self.destination,
                options: self.options
            )
        case .block(let format, let cacheMode, let syncMode):
            return .block(
                format: format,
                source: self.source,
                destination: self.destination,
                options: self.options,
                runtimeOptions: [
                    "\(Filesystem.CacheMode.vzRuntimeOptionKey)=\(cacheMode.asVZRuntimeOption)",
                    "\(Filesystem.SyncMode.vzRuntimeOptionKey)=\(syncMode.asVZRuntimeOption)",
                ],
            )
        case .volume(_, let format, let cacheMode, let syncMode):
            return .block(
                format: format,
                source: self.source,
                destination: self.destination,
                options: self.options,
                runtimeOptions: [
                    "\(Filesystem.CacheMode.vzRuntimeOptionKey)=\(cacheMode.asVZRuntimeOption)",
                    "\(Filesystem.SyncMode.vzRuntimeOptionKey)=\(syncMode.asVZRuntimeOption)",
                ],
            )
        }
    }

    func isSocket() throws -> Bool {
        if !self.isVirtiofs {
            return false
        }
        let info = try File.info(self.source)
        return info.isSocket
    }
}

extension Filesystem.CacheMode {
    static let vzRuntimeOptionKey = "vzDiskImageCachingMode"

    var asVZRuntimeOption: String {
        switch self {
        case .on: "cached"
        case .off: "uncached"
        case .auto: "automatic"
        }
    }
}

extension Filesystem.SyncMode {
    static let vzRuntimeOptionKey = "vzDiskImageSynchronizationMode"

    var asVZRuntimeOption: String {
        switch self {
        case .full: "full"
        case .fsync: "fsync"
        case .nosync: "none"
        }
    }
}

struct MultiWriter: Writer {
    let handles: [FileHandle]

    init(handles: [FileHandle]) {
        self.handles = handles
    }

    func close() throws {
        for handle in handles {
            try handle.close()
        }
    }

    func write(_ data: Data) throws {
        for handle in handles {
            try handle.write(contentsOf: data)
        }
    }
}

extension FileHandle: @retroactive ReaderStream, @retroactive Writer {
    public func write(_ data: Data) throws {
        try self.write(contentsOf: data)
    }

    public func stream() -> AsyncStream<Data> {
        .init { cont in
            self.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    self.readabilityHandler = nil
                    cont.finish()
                    return
                }
                cont.yield(data)
            }
        }
    }
}

// MARK: State handler and bundle creation helpers

extension RuntimeService {
    private func initializeWaiters(for id: String) throws {
        guard waiters[id] == nil else {
            throw ContainerizationError(.invalidState, message: "waiter for \(id) already initialized")
        }
        waiters[id] = ExitWaiter()
    }

    private func waitForExit(id: String, cont: CheckedContinuation<ExitStatus, Never>) {
        guard let waiter = waiters[id] else {
            // No waiter was initialized at all, resume immediately
            cont.resume(returning: ExitStatus(exitCode: -1))
            return
        }

        waiter.wait(cont)
    }

    private func releaseWaiters(for id: String, status: ExitStatus) {
        waiters[id]?.doExit(exitStatus: status)
    }

    private func setUnderlyingProcess(_ id: String, _ process: LinuxProcess) throws {
        guard var info = self.processes[id] else {
            throw ContainerizationError(.invalidState, message: "process \(id) not found")
        }
        info.process = process
        self.processes[id] = info
    }

    private func setProcessState(id: String, state: State) throws {
        guard var info = self.processes[id] else {
            throw ContainerizationError(.invalidState, message: "process \(id) not found")
        }
        info.state = state
        self.processes[id] = info
    }

    private func setContainer(_ info: ContainerInfo) {
        self.containers[info.id] = info
    }

    private func setSandbox(_ sandbox: any Sandbox) {
        self.sandbox = sandbox
    }

    private func setNetworkSessions(_ sessions: [XPCClientSession]) {
        self.networkSessions = sessions
    }

    private func addNewProcess(_ id: String, in containerId: String, _ config: ProcessConfiguration, _ io: [FileHandle?]) throws {
        guard self.processes[id] == nil else {
            throw ContainerizationError(.invalidArgument, message: "process \(id) already exists")
        }
        self.processes[id] = ProcessInfo(containerId: containerId, config: config, process: nil, state: .created, io: io)
    }

    private struct ProcessInfo {
        /// The container in the sandbox the process runs in.
        let containerId: String
        let config: ProcessConfiguration
        var process: LinuxProcess?
        var state: State
        let io: [FileHandle?]
    }

    private struct ContainerInfo {
        let config: ContainerConfiguration
        let attachments: [Attachment]
        let bundle: ContainerResource.Bundle
        let io: (in: FileHandle?, out: MultiWriter?, err: MultiWriter?)

        var id: String { config.id }
    }

    /// States the underlying sandbox can be in.
    public enum State: Sendable, Equatable {
        /// Sandbox is created. This should be what the service starts the sandbox in.
        case created
        /// Bootstrap will transition a .created state to .booted.
        case booted
        /// startProcess on the init process will transition .booted to .running.
        case running
        /// At the beginning of stop() .running will be transitioned to .stopping.
        case stopping
        /// Once a stop is successful, .stopping will transition to .stopped.
        case stopped
        /// .shuttingDown will be the last state the runtime service will ever be in. Shortly
        /// afterwards the process will exit.
        case shuttingDown
    }

    func setState(_ new: State) {
        self.state = new
    }

    /// Check if a bundle exists at the given path
    private func bundleExists(at path: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return false
        }

        let bundle = ContainerResource.Bundle(path: path)
        if bundle.isPod {
            return true
        }
        do {
            _ = try bundle.configuration
            return true
        } catch {
            return false
        }
    }

    /// Create bundle from RuntimeConfiguration
    private func createBundle(at root: URL? = nil) throws {
        do {
            let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: root ?? self.root)
            _ = try ContainerResource.Bundle.create(
                path: runtimeConfig.path,
                initialFilesystem: runtimeConfig.initialFilesystem,
                kernel: runtimeConfig.kernel,
                containerConfiguration: runtimeConfig.containerConfiguration,
                podConfiguration: runtimeConfig.podConfiguration,
                containerRootFilesystem: runtimeConfig.containerRootFilesystem,
                options: runtimeConfig.options
            )
            self.log.info("created bundle", metadata: ["configPath": "\(runtimeConfig.path)"])
        } catch {
            self.log.error("failed to create bundle", metadata: ["error": "\(error)"])
            throw error
        }
    }
}
