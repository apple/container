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

//

import ContainerClient
import ContainerNetworkService
import ContainerPersistence
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

import struct ContainerizationOCI.Mount
import struct ContainerizationOCI.Process

/// An XPC service that manages the lifecycle of a single VM-backed container.
public actor SandboxService {
    private let root: URL
    private let interfaceStrategy: InterfaceStrategy
    private var container: ContainerInfo?
    private let monitor: ExitMonitor
    private let eventLoopGroup: any EventLoopGroup
    private var waiters: [String: [CheckedContinuation<Int32, Never>]] = [:]
    private let lock: AsyncLock = AsyncLock()
    private let log: Logging.Logger
    private var state: State = .created
    private var processes: [String: ProcessInfo] = [:]
    private var socketForwarders: [SocketForwarderResult] = []

    /// Create an instance with a bundle that describes the container.
    ///
    /// - Parameters:
    ///   - root: The file URL for the bundle root.
    ///   - interfaceStrategy: The strategy for producing network interface
    ///     objects for each network to which the container attaches.
    ///   - log: The destination for log messages.
    public init(root: URL, interfaceStrategy: InterfaceStrategy, eventLoopGroup: any EventLoopGroup, log: Logger) {
        self.root = root
        self.interfaceStrategy = interfaceStrategy
        self.log = log
        self.monitor = ExitMonitor(log: log)
        self.eventLoopGroup = eventLoopGroup
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

            let bundle = ContainerClient.Bundle(path: self.root)
            try bundle.createLogFile()

            let vmm = VZVirtualMachineManager(
                kernel: try bundle.kernel,
                initialFilesystem: bundle.initialFilesystem.asMount,
                bootlog: bundle.bootlog.path,
                logger: self.log
            )
            var config = try bundle.configuration

            // Dynamically configure the DNS nameserver from a network if no explicit configuration
            if let dns = config.dns, dns.nameservers.isEmpty {
                if let nameserver = try await self.getDefaultNameserver(attachmentConfigurations: config.networks) {
                    config.dns = ContainerConfiguration.DNSConfiguration(
                        nameservers: [nameserver],
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
                let (attachment, additionalData) = try await client.allocate(hostname: network.options.hostname)
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
                    let primaryIfaceAddr = interfaces[0].address
                    let ip = primaryIfaceAddr.split(separator: "/")
                    hostsEntries.append(
                        Hosts.Entry(
                            ipAddress: String(ip[0]),
                            hostnames: [czConfig.hostname],
                        ))
                }
                czConfig.hosts = Hosts(entries: hostsEntries)
            }

            await self.setContainer(
                ContainerInfo(
                    container: container,
                    config: config,
                    attachments: attachments,
                    bundle: bundle,
                    io: (in: stdin, out: stdout, err: stderr)
                ))

            do {
                try await container.create()
                try await self.monitor.registerProcess(id: config.id, onExit: self.onContainerExit)
                if !container.interfaces.isEmpty {
                    let firstCidr = try CIDRAddress(container.interfaces[0].address)
                    let ipAddress = firstCidr.address.description
                    try await self.startSocketForwarders(containerIpAddress: ipAddress, publishedPorts: config.publishedPorts)
                }
                await self.setState(.booted)
            } catch {
                do {
                    try await self.cleanupContainer()
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
        self.log.info("`start` xpc handler")
        return try await self.lock.withLock { lock in
            let id = try message.id()
            let containerInfo = try await self.getContainer()
            let containerId = containerInfo.container.id
            if id == containerId {
                try await self.startInitProcess(lock: lock)
                await self.setState(.running)
                try await self.sendContainerEvent(.containerStart(id: id))
            } else {
                try await self.startExecProcess(processId: id, lock: lock)
            }
            return message.reply()
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

        self.setState(.starting)
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
            try? await self.cleanupContainer()
            self.setState(.created)
            try await self.sendContainerEvent(.containerExit(id: id, exitCode: -1))
            throw error
        }
    }

    private func startExecProcess(processId id: String, lock: AsyncLock.Context) async throws {
        let container = try self.getContainer().container
        guard let processInfo = self.processes[id] else {
            throw ContainerizationError(.notFound, message: "Process with id \(id)")
        }

        let czConfig = self.configureProcessConfig(config: processInfo.config, stdio: processInfo.io)

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

    private func startSocketForwarders(containerIpAddress: String, publishedPorts: [PublishPort]) async throws {
        var forwarders: [SocketForwarderResult] = []
        try await withThrowingTaskGroup(of: SocketForwarderResult.self) { group in
            for publishedPort in publishedPorts {
                let proxyAddress = try SocketAddress(ipAddress: publishedPort.hostAddress, port: Int(publishedPort.hostPort))
                let serverAddress = try SocketAddress(ipAddress: containerIpAddress, port: Int(publishedPort.containerPort))
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
                    return try await forwarder.run().get()
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
            case .created, .stopped(_), .starting, .stopping:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot exec: container is not running"
                )
            case .running, .booted:
                let id = try message.id()
                let config = try message.processConfig()
                let stdio = message.stdio()

                await self.addNewProcess(id, config, stdio)

                try await self.monitor.registerProcess(
                    id: id,
                    onExit: { id, code in
                        guard let process = await self.processes[id]?.process else {
                            throw ContainerizationError(
                                .invalidState,
                                message: "ProcessInfo missing for process \(id)"
                            )
                        }
                        for cc in await self.waiters[id] ?? [] {
                            cc.resume(returning: code)
                        }
                        await self.removeWaiters(for: id)
                        try await process.delete()
                        try await self.setProcessState(id: id, state: .stopped(code))
                    }
                )

                return message.reply()
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
        case .created, .stopped(_), .starting, .booted:
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
        let reply = try await self.lock.withLock { [self] _ in
            switch await self.state {
            case .stopped(_), .created, .stopping:
                return message.reply()
            case .starting:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot stop: container is not running"
                )
            case .running, .booted:
                let ctr = try await getContainer()
                let stopOptions = try message.stopOptions()
                do {
                    try await gracefulStopContainer(
                        ctr.container,
                        stopOpts: stopOptions
                    )
                } catch {
                    log.notice("failed to stop sandbox gracefully: \(error)")
                }
                await setState(.stopping)
                return message.reply()
            }
        }
        do {
            try await cleanupContainer()
        } catch {
            self.log.error("failed to cleanup container: \(error)")
        }
        return reply
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
            case .created, .stopped, .starting, .booted, .stopping:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot kill: container is not running"
                )
            case .running:
                let ctr = try await getContainer()
                let id = try message.id()
                if id != ctr.container.id {
                    guard let processInfo = await self.processes[id] else {
                        throw ContainerizationError(.invalidState, message: "Process \(id) does not exist")
                    }

                    guard let proc = processInfo.process else {
                        throw ContainerizationError(.invalidState, message: "Process \(id) not started")
                    }
                    try await proc.kill(Int32(try message.signal()))
                    return message.reply()
                }

                // TODO: fix underlying signal value to int64
                try await ctr.container.kill(Int32(try message.signal()))
                return message.reply()
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
        return try await self.lock.withLock { [self] _ in
            switch await self.state {
            case .created, .stopped, .starting, .booted, .stopping:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot resize: container is not running"
                )
            case .running:
                let id = try message.id()
                let ctr = try await getContainer()
                let width = message.uint64(key: .width)
                let height = message.uint64(key: .height)
                if id != ctr.container.id {
                    guard let processInfo = await self.processes[id] else {
                        throw ContainerizationError(.invalidState, message: "Process \(id) does not exist")
                    }

                    guard let proc = processInfo.process else {
                        throw ContainerizationError(.invalidState, message: "Process \(id) not started")
                    }

                    try await proc.resize(to: .init(width: UInt16(width), height: UInt16(height)))
                    return message.reply()
                }

                try await ctr.container.resize(to: .init(width: UInt16(width), height: UInt16(height)))
                return message.reply()
            }
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
        guard let id = message.string(key: .id) else {
            throw ContainerizationError(.invalidArgument, message: "Missing id in wait xpc message")
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
                    throw ContainerizationError(.notFound, message: "Process with id \(id)")
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
            reply.set(key: .exitCode, value: Int64(cachedCode))
            return reply
        }

        let exitCode = await withCheckedContinuation { cc in
            // Is this safe since we are in an actor? :(
            self.addWaiter(id: id, cont: cc)
        }
        let reply = message.reply()
        reply.set(key: .exitCode, value: Int64(exitCode))
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
        case .starting, .created, .stopped, .stopping:
            throw ContainerizationError(
                .invalidState,
                message: "cannot dial: container is not running"
            )
        case .running, .booted:
            let port = message.uint64(key: .port)
            guard port > 0 else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no vsock port supplied for dial"
                )
            }

            let ctr = try getContainer()
            let fh = try await ctr.container.dialVsock(port: UInt32(port))

            let reply = message.reply()
            reply.set(key: .fd, value: fh)
            return reply
        }
    }

    private func onContainerExit(id: String, code: Int32) async throws {
        self.log.info("init process exited with: \(code)")

        try await self.lock.withLock { [self] _ in
            let ctrInfo = try await getContainer()
            let ctr = ctrInfo.container
            // Did someone explicitly call stop and we're already
            // cleaning up?
            switch await self.state {
            case .stopped(_):
                return
            default:
                break
            }

            do {
                try await ctr.stop()
            } catch {
                log.notice("failed to stop sandbox gracefully: \(error)")
            }

            do {
                try await cleanupContainer()
            } catch {
                self.log.error("failed to cleanup container: \(error)")
            }
            await setState(.stopped(code))
            let waiters = await self.waiters[id] ?? []
            for cc in waiters {
                cc.resume(returning: code)
            }
            await self.removeWaiters(for: id)
            try await self.sendContainerEvent(.containerExit(id: id, exitCode: Int64(code)))
            exit(code)
        }
    }

    private static func configureContainer(
        czConfig: inout LinuxContainer.Configuration,
        config: ContainerConfiguration
    ) throws {
        czConfig.cpus = config.resources.cpus
        czConfig.memoryInBytes = config.resources.memoryInBytes
        czConfig.rosetta = config.rosetta
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

        czConfig.hostname = config.id

        if let dns = config.dns {
            czConfig.dns = DNS(
                nameservers: dns.nameservers, domain: dns.domain,
                searchDomains: dns.searchDomains, options: dns.options)
        }

        Self.configureInitialProcess(czConfig: &czConfig, process: config.initProcess)
    }

    private func getDefaultNameserver(attachmentConfigurations: [AttachmentConfiguration]) async throws -> String? {
        for attachmentConfiguration in attachmentConfigurations {
            let client = NetworkClient(id: attachmentConfiguration.network)
            let state = try await client.state()
            guard case .running(_, let status) = state else {
                continue
            }
            return status.gateway
        }

        return nil
    }

    private static func configureInitialProcess(
        czConfig: inout LinuxContainer.Configuration,
        process: ProcessConfiguration
    ) {
        czConfig.process.arguments = [process.executable] + process.arguments
        czConfig.process.environmentVariables = process.environment
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

    private nonisolated func configureProcessConfig(config: ProcessConfiguration, stdio: [FileHandle?]) -> LinuxContainer.Configuration.Process {
        var proc = LinuxContainer.Configuration.Process()
        proc.stdin = stdio[0]
        proc.stdout = stdio[1]
        proc.stderr = stdio[2]

        proc.arguments = [config.executable] + config.arguments
        proc.environmentVariables = config.environment
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

    private func gracefulStopContainer(_ lc: LinuxContainer, stopOpts: ContainerStopOptions) async throws {
        // Try and gracefully shut down the process. Even if this succeeds we need to power off
        // the vm, but we should try this first always.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await lc.wait()
                }
                group.addTask {
                    try await lc.kill(stopOpts.signal)
                    try await Task.sleep(for: .seconds(stopOpts.timeoutInSeconds))
                    try await lc.kill(SIGKILL)
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {}
        // Now actually bring down the vm.
        try await lc.stop()
    }

    private func cleanupContainer() async throws {
        // Give back our lovely IP(s)
        await self.stopSocketForwarders()
        let containerInfo = try self.getContainer()
        for attachment in containerInfo.attachments {
            let client = NetworkClient(id: attachment.network)
            do {
                try await client.deallocate(hostname: attachment.hostname)
            } catch {
                self.log.error("failed to deallocate hostname \(attachment.hostname) on network \(attachment.network): \(error)")
            }
        }
    }

    private func sendContainerEvent(_ event: ContainerEvent) async throws {
        let serviceIdentifier = "com.apple.container.apiserver"
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .containerEvent)

        let data = try JSONEncoder().encode(event)
        message.set(key: .containerEvent, value: data)
        try await client.send(message)
    }

}

extension XPCMessage {
    fileprivate func signal() throws -> Int64 {
        self.int64(key: .signal)
    }

    fileprivate func stopOptions() throws -> ContainerStopOptions {
        guard let data = self.dataNoCopy(key: .stopOptions) else {
            throw ContainerizationError(.invalidArgument, message: "empty StopOptions")
        }
        return try JSONDecoder().decode(ContainerStopOptions.self, from: data)
    }

    fileprivate func setState(_ state: SandboxSnapshot) throws {
        let data = try JSONEncoder().encode(state)
        self.set(key: .snapshot, value: data)
    }

    fileprivate func stdio() -> [FileHandle?] {
        var handles = [FileHandle?](repeating: nil, count: 3)
        if let stdin = self.fileHandle(key: .stdin) {
            handles[0] = stdin
        }
        if let stdout = self.fileHandle(key: .stdout) {
            handles[1] = stdout
        }
        if let stderr = self.fileHandle(key: .stderr) {
            handles[2] = stderr
        }
        return handles
    }

    fileprivate func setFileHandle(_ handle: FileHandle) {
        self.set(key: .fd, value: handle)
    }

    fileprivate func processConfig() throws -> ProcessConfiguration {
        guard let data = self.dataNoCopy(key: .processConfig) else {
            throw ContainerizationError(.invalidArgument, message: "empty process configuration")
        }
        return try JSONDecoder().decode(ProcessConfiguration.self, from: data)
    }
}

extension ContainerClient.Bundle {
    /// The pathname for the workload log file.
    public var containerLog: URL {
        path.appendingPathComponent("stdio.log")
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
        case .block(let format, _, _):
            return .block(
                format: format,
                source: self.source,
                destination: self.destination,
                options: self.options
            )
        case .volume(_, let format, _, _):
            return .block(
                format: format,
                source: self.source,
                destination: self.destination,
                options: self.options
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
    private func addWaiter(id: String, cont: CheckedContinuation<Int32, Never>) {
        var current = self.waiters[id] ?? []
        current.append(cont)
        self.waiters[id] = current
    }

    private func removeWaiters(for id: String) {
        self.waiters[id] = []
    }

    private func setUnderlyingProcess(_ id: String, _ process: LinuxProcess) throws {
        guard var info = self.processes[id] else {
            throw ContainerizationError(.invalidState, message: "Process \(id) not found")
        }
        info.process = process
        self.processes[id] = info
    }

    private func setProcessState(id: String, state: State) throws {
        guard var info = self.processes[id] else {
            throw ContainerizationError(.invalidState, message: "Process \(id) not found")
        }
        info.state = state
        self.processes[id] = info
    }

    private func setContainer(_ info: ContainerInfo) {
        self.container = info
    }

    private func addNewProcess(_ id: String, _ config: ProcessConfiguration, _ io: [FileHandle?]) {
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
        let bundle: ContainerClient.Bundle
        let io: (in: FileHandle?, out: MultiWriter?, err: MultiWriter?)
    }

    public enum State: Sendable, Equatable {
        case created
        case booted
        case starting
        case running
        case stopping
        case stopped(Int32)
    }

    func setState(_ new: State) {
        self.state = new
    }
}
