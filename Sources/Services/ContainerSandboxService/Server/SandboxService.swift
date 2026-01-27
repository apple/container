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

import ContainerNetworkServiceClient
import ContainerPersistence
import ContainerResource
import ContainerSandboxServiceClient
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

/// An XPC service that manages the lifecycle of a single VM-backed container.
public actor SandboxService {
    private let connection: xpc_connection_t
    private let root: URL
    private let interfaceStrategy: InterfaceStrategy
    private var container: ContainerInfo?
    private let monitor: ExitMonitor
    private let eventLoopGroup: any EventLoopGroup
    private var waiters: [String: [CheckedContinuation<ExitStatus, Never>]] = [:]
    private let lock: AsyncLock = AsyncLock()
    private let log: Logging.Logger
    private var state: State = .created
    private var processes: [String: ProcessInfo] = [:]
    private var socketForwarders: [SocketForwarderResult] = []

    private static let sshAuthSocketGuestPath = "/run/host-services/ssh-auth.sock"
    private static let sshAuthSocketEnvVar = "SSH_AUTH_SOCK"

    private static func sshAuthSocketHostUrl(config: ContainerConfiguration) -> URL? {
        if config.ssh, let sshSocket = Foundation.ProcessInfo.processInfo.environment[Self.sshAuthSocketEnvVar] {
            return URL(fileURLWithPath: sshSocket)
        }
        return nil
    }

    /// Create an instance with a bundle that describes the container.
    ///
    /// - Parameters:
    ///   - root: The file URL for the bundle root.
    ///   - interfaceStrategy: The strategy for producing network interface
    ///     objects for each network to which the container attaches.
    ///   - log: The destination for log messages.
    public init(
        root: URL,
        interfaceStrategy: InterfaceStrategy,
        eventLoopGroup: any EventLoopGroup,
        connection: xpc_connection_t,
        log: Logger
    ) {
        self.root = root
        self.interfaceStrategy = interfaceStrategy
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
    ///     with the sandbox service.
    @Sendable
    public func createEndpoint(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.info("`createEndpoint` xpc handler")
        let endpoint = xpc_endpoint_create(self.connection)
        let reply = message.reply()
        reply.set(key: SandboxKeys.sandboxServiceEndpoint.rawValue, value: endpoint)
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
        self.log.info("`bootstrap` xpc handler")
        return try await self.lock.withLock { _ in
            guard await self.state == .created else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container expected to be in created state, got: \(await self.state)"
                )
            }

            let bundle = ContainerResource.Bundle(path: self.root)
            try bundle.createLogFile()

            var config = try bundle.configuration

            var kernel = try bundle.kernel
            kernel.commandLine.kernelArgs.append("oops=panic")
            let vmm = VZVirtualMachineManager(
                kernel: kernel,
                initialFilesystem: bundle.initialFilesystem.asMount,
                rosetta: config.rosetta,
                logger: self.log
            )

            // Dynamically configure the DNS nameserver from a network if no explicit configuration
            if let dns = config.dns, dns.nameservers.isEmpty {
                let defaultNameservers = try await self.getDefaultNameservers(attachmentConfigurations: config.networks)
                if !defaultNameservers.isEmpty {
                    config.dns = ContainerConfiguration.DNSConfiguration(
                        nameservers: defaultNameservers,
                        domain: dns.domain,
                        searchDomains: dns.searchDomains,
                        options: dns.options
                    )
                }
            }

            var attachments: [Attachment] = []
            var interfaces: [Interface] = []
            for index in 0..<config.networks.count {
                let network = config.networks[index]
                let client = NetworkClient(id: network.network)
                let (attachment, additionalData) = try await client.allocate(hostname: network.options.hostname, macAddress: network.options.macAddress)
                attachments.append(attachment)

                let interface = try self.interfaceStrategy.toInterface(
                    attachment: attachment,
                    interfaceIndex: index,
                    additionalData: additionalData
                )
                interfaces.append(interface)
            }

            let stdio = message.stdio()
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

            let stdin = {
                stdio[0] ?? nil
            }()

            let id = config.id
            let rootfs = try bundle.containerRootfs.asMount
            let container = try LinuxContainer(id, rootfs: rootfs, vmm: vmm, logger: self.log) { czConfig in
                try Self.configureContainer(czConfig: &czConfig, config: config)
                czConfig.interfaces = interfaces
                czConfig.process.stdout = stdout
                czConfig.process.stderr = stderr
                czConfig.process.stdin = stdin
                // NOTE: We can support a user providing new entries eventually, but for now craft
                // a default /etc/hosts.
                var hostsEntries = [Hosts.Entry.localHostIPV4()]
                if !interfaces.isEmpty {
                    let primaryIfaceAddr = interfaces[0].ipv4Address
                    hostsEntries.append(
                        Hosts.Entry(
                            ipAddress: primaryIfaceAddr.address.description,
                            hostnames: [czConfig.hostname],
                        ))
                }
                czConfig.hosts = Hosts(entries: hostsEntries)
                czConfig.bootLog = BootLog.file(path: bundle.bootlog, append: true)
            }

            let ctrInfo = ContainerInfo(
                container: container,
                config: config,
                attachments: attachments,
                bundle: bundle,
                io: (in: stdin, out: stdout, err: stderr)
            )
            await self.setContainer(ctrInfo)

            do {
                try await container.create()
                try await self.monitor.registerProcess(id: config.id, onExit: self.onContainerExit)
                if !container.interfaces.isEmpty {
                    try await self.startSocketForwarders(attachment: attachments[0], publishedPorts: config.publishedPorts)
                }
                await self.setState(.booted)
            } catch {
                do {
                    try await self.cleanupContainer(containerInfo: ctrInfo)
                    await self.setState(.created)
                } catch {
                    self.log.error("failed to cleanup container: \(error)")
                }
                throw error
            }
            return message.reply()
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
        self.log.info("`startProcess` xpc handler")
        return try await self.lock.withLock { lock in
            let id = try message.id()
            let containerInfo = try await self.getContainer()
            let containerId = containerInfo.container.id
            if id == containerId {
                try await self.startInitProcess(lock: lock)
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
        self.log.info("`statistics` xpc handler")
        return try await self.lock.withLock { lock in
            let containerInfo = try await self.getContainer()
            let stats = try await containerInfo.container.statistics()

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
            reply.set(key: SandboxKeys.statistics.rawValue, value: data)
            return reply
        }
    }

    /// Shutdown the SandboxService.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func shutdown(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.info("`shutdown` xpc handler")

        return try await self.lock.withLock { _ in
            switch await self.state {
            case .created, .stopped(_), .stopping:
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
        log.info("`createProcess` xpc handler")
        return try await self.lock.withLock { [self] _ in
            switch await self.state {
            case .running, .booted:
                let id = try message.id()
                let config = try message.processConfig()
                let stdio = message.stdio()

                try await self.addNewProcess(id, config, stdio)

                try await self.monitor.registerProcess(
                    id: id,
                    onExit: { id, exitStatus in
                        guard let process = await self.processes[id]?.process else {
                            throw ContainerizationError(
                                .invalidState,
                                message: "ProcessInfo missing for process \(id)"
                            )
                        }
                        for cc in await self.waiters[id] ?? [] {
                            cc.resume(returning: exitStatus)
                        }
                        await self.removeWaiters(for: id)
                        try await process.delete()
                        try await self.setProcessState(id: id, state: .stopped(exitStatus.exitCode))
                    }
                )

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
        self.log.info("`state` xpc handler")
        var status: RuntimeStatus = .unknown
        var networks: [Attachment] = []
        var cs: ContainerSnapshot?

        switch state {
        case .created, .stopped(_), .booted, .shuttingDown:
            status = .stopped
        case .stopping:
            status = .stopping
        case .running:
            let ctr = try getContainer()

            status = .running
            networks = ctr.attachments
            cs = ContainerSnapshot(
                configuration: ctr.config,
                status: RuntimeStatus.running,
                networks: networks
            )
        }

        let reply = message.reply()
        try reply.setState(
            .init(
                status: status,
                networks: networks,
                containers: cs != nil ? [cs!] : []
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
        self.log.info("`stop` xpc handler")
        return try await self.lock.withLock { _ in
            switch await self.state {
            case .running, .booted:
                await self.setState(.stopping)

                let ctr = try await self.getContainer()
                let stopOptions = try message.stopOptions()
                let exitStatus = try await self.gracefulStopContainer(
                    ctr.container,
                    stopOpts: stopOptions
                )

                do {
                    if case .stopped(_) = await self.state {
                        return message.reply()
                    }
                    try await self.cleanupContainer(containerInfo: ctr, exitStatus: exitStatus)
                } catch {
                    self.log.error("failed to cleanup container: \(error)")
                }
                await self.setState(.stopped(exitStatus.exitCode))
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
    public func kill(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.info("`kill` xpc handler")
        return try await self.lock.withLock { [self] _ in
            switch await self.state {
            case .running:
                let ctr = try await getContainer()
                let id = try message.id()
                if id != ctr.container.id {
                    guard let processInfo = await self.processes[id] else {
                        throw ContainerizationError(.invalidState, message: "process \(id) does not exist")
                    }

                    guard let proc = processInfo.process else {
                        throw ContainerizationError(.invalidState, message: "process \(id) not started")
                    }
                    try await proc.kill(Int32(try message.signal()))
                    return message.reply()
                }

                // TODO: fix underlying signal value to int64
                try await ctr.container.kill(Int32(try message.signal()))
                return message.reply()
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot kill: container is not running"
                )
            }
        }
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
        self.log.info("`resize` xpc handler")
        switch self.state {
        case .running:
            let id = try message.id()
            let ctr = try getContainer()
            let width = message.uint64(key: SandboxKeys.width.rawValue)
            let height = message.uint64(key: SandboxKeys.height.rawValue)

            if id != ctr.container.id {
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

                try await proc.resize(
                    to: .init(
                        width: UInt16(width),
                        height: UInt16(height))
                )
            } else {
                try await ctr.container.resize(
                    to: .init(
                        width: UInt16(width),
                        height: UInt16(height))
                )
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
        self.log.info("`wait` xpc handler")
        guard let id = message.string(key: SandboxKeys.id.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "missing id in wait xpc message")
        }

        let cachedCode: Int32? = try await self.lock.withLock { _ in
            let ctrInfo = try await self.getContainer()
            let ctr = ctrInfo.container
            if id == ctr.id {
                switch await self.state {
                case .stopped(let code):
                    return code
                default:
                    break
                }
            } else {
                guard let processInfo = await self.processes[id] else {
                    throw ContainerizationError(.notFound, message: "process with id \(id)")
                }
                switch processInfo.state {
                case .stopped(let code):
                    return code
                default:
                    break
                }
            }
            return nil
        }
        if let cachedCode {
            let reply = message.reply()
            reply.set(key: SandboxKeys.exitCode.rawValue, value: Int64(cachedCode))
            return reply
        }

        let exitStatus = await withCheckedContinuation { cc in
            // Is this safe since we are in an actor? :(
            self.addWaiter(id: id, cont: cc)
        }
        let reply = message.reply()
        reply.set(key: SandboxKeys.exitCode.rawValue, value: Int64(exitStatus.exitCode))
        reply.set(key: SandboxKeys.exitedAt.rawValue, value: exitStatus.exitedAt)
        return reply
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
        self.log.info("`dial` xpc handler")
        switch self.state {
        case .running, .booted:
            let port = message.uint64(key: SandboxKeys.port.rawValue)
            guard port > 0 else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no vsock port supplied for dial"
                )
            }

            let ctr = try getContainer()
            let fh = try await ctr.container.dialVsock(port: UInt32(port))

            let reply = message.reply()
            reply.set(key: SandboxKeys.fd.rawValue, value: fh)
            return reply
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot dial: container is not running"
            )
        }
    }

    private func startInitProcess(lock: AsyncLock.Context) async throws {
        let info = try self.getContainer()
        let container = info.container
        let id = container.id

        guard self.state == .booted else {
            throw ContainerizationError(
                .invalidState,
                message: "container expected to be in booted state, got: \(self.state)"
            )
        }

        do {
            let io = info.io

            try await container.start()
            let waitFunc: ExitMonitor.WaitHandler = {
                let code = try await container.wait()
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
            try? await self.cleanupContainer(containerInfo: info)
            self.setState(.created)
            throw error
        }
    }

    private func startExecProcess(processId id: String, lock: AsyncLock.Context) async throws {
        let container = try self.getContainer().container
        guard let processInfo = self.processes[id] else {
            throw ContainerizationError(.notFound, message: "process with id \(id)")
        }

        let containerInfo = try self.getContainer()

        let czConfig = self.configureProcessConfig(config: processInfo.config, stdio: processInfo.io, containerConfig: containerInfo.config)

        let process = try await container.exec(id, configuration: czConfig)
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
        self.log.info("init process exited with: \(exitStatus)")

        try await self.lock.withLock { [self] _ in
            let ctrInfo = try await getContainer()

            switch await self.state {
            case .stopped(_), .stopping:
                return
            default:
                break
            }

            do {
                try await cleanupContainer(containerInfo: ctrInfo, exitStatus: exitStatus)
            } catch {
                self.log.error("failed to cleanup container: \(error)")
            }
            await setState(.stopped(exitStatus.exitCode))
        }
    }

    private static func configureContainer(
        czConfig: inout LinuxContainer.Configuration,
        config: ContainerConfiguration
    ) throws {
        czConfig.cpus = config.resources.cpus
        czConfig.memoryInBytes = config.resources.memoryInBytes
        czConfig.sysctl = config.sysctls.reduce(into: [String: String]()) {
            $0[$1.key] = $1.value
        }
        // If the host doesn't support this, we'll throw on container creation.
        czConfig.virtualization = config.virtualization

        for mount in config.mounts {
            if try mount.isSocket() {
                let socket = UnixSocketConfiguration(
                    source: URL(filePath: mount.source),
                    destination: URL(filePath: mount.destination)
                )
                czConfig.sockets.append(socket)
            } else {
                czConfig.mounts.append(mount.asMount)
            }
        }

        for publishedSocket in config.publishedSockets {
            let socketConfig = UnixSocketConfiguration(
                source: publishedSocket.containerPath,
                destination: publishedSocket.hostPath,
                permissions: publishedSocket.permissions,
                direction: .outOf
            )
            czConfig.sockets.append(socketConfig)
        }

        if let socketUrl = Self.sshAuthSocketHostUrl(config: config) {
            let socketPath = socketUrl.path(percentEncoded: false)
            let attrs = try? FileManager.default.attributesOfItem(atPath: socketPath)
            let permissions = (attrs?[.posixPermissions] as? NSNumber)
                .map { FilePermissions(rawValue: mode_t($0.intValue)) }
            let socketConfig = UnixSocketConfiguration(
                source: socketUrl,
                destination: URL(fileURLWithPath: Self.sshAuthSocketGuestPath),
                permissions: permissions,
                direction: .into,
            )
            czConfig.sockets.append(socketConfig)
        }

        let containerId = config.id
        czConfig.hostname =
            containerId.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0) } ?? containerId

        if let dns = config.dns {
            czConfig.dns = DNS(
                nameservers: dns.nameservers, domain: dns.domain,
                searchDomains: dns.searchDomains, options: dns.options)
        }

        Self.configureInitialProcess(czConfig: &czConfig, config: config)
    }

    private func getDefaultNameservers(attachmentConfigurations: [AttachmentConfiguration]) async throws -> [String] {
        for attachmentConfiguration in attachmentConfigurations {
            let client = NetworkClient(id: attachmentConfiguration.network)
            let state = try await client.state()
            guard case .running(_, let status) = state else {
                continue
            }
            return [status.ipv4Gateway.description]
        }

        return []
    }

    private static func configureInitialProcess(
        czConfig: inout LinuxContainer.Configuration,
        config: ContainerConfiguration
    ) {
        let process = config.initProcess

        czConfig.process.arguments = [process.executable] + process.arguments
        czConfig.process.environmentVariables = process.environment

        if Self.sshAuthSocketHostUrl(config: config) != nil {
            if !czConfig.process.environmentVariables.contains(where: { $0.starts(with: "\(Self.sshAuthSocketEnvVar)=") }) {
                czConfig.process.environmentVariables.append("\(Self.sshAuthSocketEnvVar)=\(Self.sshAuthSocketGuestPath)")
            }
        }

        czConfig.process.terminal = process.terminal
        czConfig.process.workingDirectory = process.workingDirectory
        czConfig.process.rlimits = process.rlimits.map {
            .init(type: $0.limit, hard: $0.hard, soft: $0.soft)
        }
        switch process.user {
        case .raw(let name):
            czConfig.process.user = .init(
                uid: 0,
                gid: 0,
                umask: nil,
                additionalGids: process.supplementalGroups,
                username: name
            )
        case .id(let uid, let gid):
            czConfig.process.user = .init(
                uid: uid,
                gid: gid,
                umask: nil,
                additionalGids: process.supplementalGroups,
                username: ""
            )
        }
    }

    private nonisolated func configureProcessConfig(config: ProcessConfiguration, stdio: [FileHandle?], containerConfig: ContainerConfiguration)
        -> LinuxProcessConfiguration
    {
        var proc = LinuxProcessConfiguration()
        proc.stdin = stdio[0]
        proc.stdout = stdio[1]
        proc.stderr = stdio[2]

        proc.arguments = [config.executable] + config.arguments
        proc.environmentVariables = config.environment

        if Self.sshAuthSocketHostUrl(config: containerConfig) != nil {
            if !proc.environmentVariables.contains(where: { $0.starts(with: "\(Self.sshAuthSocketEnvVar)=") }) {
                proc.environmentVariables.append("\(Self.sshAuthSocketEnvVar)=\(Self.sshAuthSocketGuestPath)")
            }
        }

        proc.terminal = config.terminal
        proc.workingDirectory = config.workingDirectory
        proc.rlimits = config.rlimits.map {
            .init(type: $0.limit, hard: $0.hard, soft: $0.soft)
        }
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

    private nonisolated func closeHandle(_ handle: Int32) throws {
        guard close(handle) == 0 else {
            guard let errCode = POSIXErrorCode(rawValue: errno) else {
                fatalError("failed to convert errno to POSIXErrorCode")
            }
            throw POSIXError(errCode)
        }
    }

    private func getContainer() throws -> ContainerInfo {
        guard let container else {
            throw ContainerizationError(
                .invalidState,
                message: "no container found"
            )
        }
        return container
    }

    private func gracefulStopContainer(_ lc: LinuxContainer, stopOpts: ContainerStopOptions) async throws -> ExitStatus {
        // Try and gracefully shut down the process. Even if this succeeds we need to power off
        // the vm, but we should try this first always.
        var code = ExitStatus(exitCode: 255)
        do {
            code = try await withThrowingTaskGroup(of: ExitStatus.self) { group in
                group.addTask {
                    try await lc.wait()
                }
                group.addTask {
                    try await lc.kill(stopOpts.signal)
                    try await Task.sleep(for: .seconds(stopOpts.timeoutInSeconds))
                    try await lc.kill(SIGKILL)

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
        } catch {}

        // Now actually bring down the vm.
        try await lc.stop()

        return code
    }

    private func cleanupContainer(containerInfo: ContainerInfo, exitStatus: ExitStatus? = nil) async throws {
        let container = containerInfo.container
        let id = container.id

        do {
            try await container.stop()
        } catch {
            self.log.error("failed to stop container during cleanup: \(error)")
        }

        // Give back our lovely IP(s)
        await self.stopSocketForwarders()
        for attachment in containerInfo.attachments {
            let client = NetworkClient(id: attachment.network)
            do {
                try await client.deallocate(hostname: attachment.hostname)
            } catch {
                self.log.error("failed to deallocate hostname \(attachment.hostname) on network \(attachment.network) during cleanup: \(error)")
            }
        }

        let status = exitStatus ?? ExitStatus(exitCode: 255)
        let waiters = self.waiters[id] ?? []
        for cc in waiters {
            cc.resume(returning: status)
        }
        self.removeWaiters(for: id)
    }
}

extension XPCMessage {
    fileprivate func signal() throws -> Int64 {
        self.int64(key: SandboxKeys.signal.rawValue)
    }

    fileprivate func stopOptions() throws -> ContainerStopOptions {
        guard let data = self.dataNoCopy(key: SandboxKeys.stopOptions.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "empty StopOptions")
        }
        return try JSONDecoder().decode(ContainerStopOptions.self, from: data)
    }

    fileprivate func setState(_ state: SandboxSnapshot) throws {
        let data = try JSONEncoder().encode(state)
        self.set(key: SandboxKeys.snapshot.rawValue, value: data)
    }

    fileprivate func stdio() -> [FileHandle?] {
        var handles = [FileHandle?](repeating: nil, count: 3)
        if let stdin = self.fileHandle(key: SandboxKeys.stdin.rawValue) {
            handles[0] = stdin
        }
        if let stdout = self.fileHandle(key: SandboxKeys.stdout.rawValue) {
            handles[1] = stdout
        }
        if let stderr = self.fileHandle(key: SandboxKeys.stderr.rawValue) {
            handles[2] = stderr
        }
        return handles
    }

    fileprivate func setFileHandle(_ handle: FileHandle) {
        self.set(key: SandboxKeys.fd.rawValue, value: handle)
    }

    fileprivate func processConfig() throws -> ProcessConfiguration {
        guard let data = self.dataNoCopy(key: SandboxKeys.processConfig.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "empty process configuration")
        }
        return try JSONDecoder().decode(ProcessConfiguration.self, from: data)
    }
}

extension ContainerResource.Bundle {
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

// MARK: State handler helpers

extension SandboxService {
    private func addWaiter(id: String, cont: CheckedContinuation<ExitStatus, Never>) {
        var current = self.waiters[id] ?? []
        current.append(cont)
        self.waiters[id] = current
    }

    private func removeWaiters(for id: String) {
        self.waiters[id] = []
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
        self.container = info
    }

    private func addNewProcess(_ id: String, _ config: ProcessConfiguration, _ io: [FileHandle?]) throws {
        guard self.processes[id] == nil else {
            throw ContainerizationError(.invalidArgument, message: "process \(id) already exists")
        }
        self.processes[id] = ProcessInfo(config: config, process: nil, state: .created, io: io)
    }

    private struct ProcessInfo {
        let config: ProcessConfiguration
        var process: LinuxProcess?
        var state: State
        let io: [FileHandle?]
    }

    private struct ContainerInfo {
        let container: LinuxContainer
        let config: ContainerConfiguration
        let attachments: [Attachment]
        let bundle: ContainerResource.Bundle
        let io: (in: FileHandle?, out: MultiWriter?, err: MultiWriter?)
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
        case stopped(Int32)
        /// .shuttingDown will be the last state the sandbox service will ever be in. Shortly
        /// afterwards the process will exit.
        case shuttingDown
    }

    func setState(_ new: State) {
        self.state = new
    }
}
