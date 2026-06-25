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
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging
import vmnet

internal final class Bridge {

    internal final class PacketBuffer {
        public let buffers: UnsafeMutableRawPointer
        public let iovs: UnsafeMutablePointer<iovec>
        public let packets: UnsafeMutablePointer<vmpktdesc>

        public let maxPacketSize: Int
        public let maxPktCount: Int

        public init(maxPktCount: Int, maxPktSize: Int) {
            self.buffers = .allocate(byteCount: maxPktCount * maxPktSize, alignment: 16)
            self.iovs = .allocate(capacity: maxPktCount)
            self.packets = .allocate(capacity: maxPktCount)
            for i in 0..<maxPktCount {
                iovs[i] = iovec(
                    iov_base: buffers.advanced(by: i * maxPktSize),
                    iov_len: maxPktSize)
                packets[i] = vmpktdesc(
                    vm_pkt_size: maxPktSize,
                    vm_pkt_iov: iovs.advanced(by: i),
                    vm_pkt_iovcnt: 1,
                    vm_flags: 0)
            }
            self.maxPacketSize = maxPktSize
            self.maxPktCount = maxPktCount
        }

        public func reset() {
            // Reset fields - vmnet_read mutates them
            for i in 0..<maxPktCount {
                packets[i].vm_pkt_size = maxPacketSize
                packets[i].vm_flags = 0
                iovs[i].iov_len = maxPacketSize
            }
        }

        deinit {
            buffers.deallocate()
            iovs.deallocate()
            packets.deallocate()
        }
    }

    // an unique identifier that serves as also as an identifier of the vmnet packet queue
    public let identifier: String

    // "our" network-side endpoint of the UNIX socket pipe to the sandbox service
    public let networkEndpoint: FileHandle

    // the remote-side endpoint of the UNIX socket pipe that the sandbox service can
    // use to communicate with us
    //
    // NOTE: shall be closed as soon as we do not need it anymore, since it will be
    // dup-ed when we send it to the sandbox service via XPC automatically
    public let sandboxEndpoint: FileHandle

    // MAC assigned to the interface by automatically vmnet
    // Note: unfortunately currently it does not seem possible to explicitly get vmnet to assign a custom MAC address
    public let macAddress: MACAddress

    // MTU reported by vmnet (usually 1500).
    public let mtu: UInt32

    private let log: Logger

    private var stopped: Bool = false

    private let interfaceRef: interface_ref
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?

    // host->sandbox
    private let hostPacketBuffer: PacketBuffer
    // sandbox->host
    private let sandboxPacketBuffer: PacketBuffer

    public init(
        identifier: String,
        hostInterface: String,
        logger: Logger,
        enableTso: Bool,
        enableChecksumOffload: Bool,
        bufferedPacketCount: Int
    ) throws {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer {
            socketpair(AF_UNIX, SOCK_DGRAM, 0, $0.baseAddress)
        }
        guard rc == 0 else {
            throw ContainerizationError(.internalError, message: "unable to create socket pairs for UNIX bridge endpoints")
        }

        let networkEndpoint = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        let sandboxEndpoint = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)

        // Make our endpoint side non blocking, so the read source can drain it in a loop.
        let flags = fcntl(networkEndpoint.fileDescriptor, F_GETFL)
        _ = fcntl(networkEndpoint.fileDescriptor, F_SETFL, flags | O_NONBLOCK)

        // vmnet interface descriptor.
        let desc = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(
            desc, vmnet_operation_mode_key,
            UInt64(vmnet.operating_modes_t.VMNET_BRIDGED_MODE.rawValue)
        )
        xpc_dictionary_set_string(desc, vmnet_shared_interface_name_key, hostInterface)
        xpc_dictionary_set_bool(desc, vmnet_enable_tso_key, enableTso)
        xpc_dictionary_set_bool(
            desc, vmnet_enable_checksum_offload_key,
            enableChecksumOffload)

        // Unfortunately, apparently not understood currently - otherwise this would maybe provide us the opportunity to
        // set a custom MAC address
        // xpc_dictionary_set_bool(desc, vmnet_allocate_mac_address_key, false)

        // start interface synchronously — vmnet posts the completion on `queue`.
        let queue = DispatchQueue(label: identifier, qos: .userInitiated)
        let sema = DispatchSemaphore(value: 0)
        var startStatus: vmnet_return_t = .VMNET_FAILURE
        var maxPacketSize = 0
        var mtu: UInt32 = 0
        var mac = ""

        let iface = vmnet_start_interface(desc, queue) { status, param in
            startStatus = status
            if status == .VMNET_SUCCESS, let param = param {
                maxPacketSize = Int(xpc_dictionary_get_uint64(param, vmnet_max_packet_size_key))
                mtu = UInt32(xpc_dictionary_get_uint64(param, vmnet_mtu_key))
                if let cstr = xpc_dictionary_get_string(param, vmnet_mac_address_key) {
                    mac = String(cString: cstr)
                }
            }
            sema.signal()
        }
        sema.wait()

        guard startStatus == .VMNET_SUCCESS, let iface = iface else {
            throw ContainerizationError(.internalError, message: "unable to start vmnet bridge interface")
        }
        guard let macAddress = try? MACAddress(mac) else {
            throw ContainerizationError(.internalError, message: "vmnet returned an invalid mac address for vmnet bridge interface")
        }

        self.log = logger

        self.identifier = identifier
        self.networkEndpoint = networkEndpoint
        self.sandboxEndpoint = sandboxEndpoint
        self.macAddress = macAddress
        self.mtu = mtu
        self.interfaceRef = iface
        self.queue = queue

        self.hostPacketBuffer = PacketBuffer(maxPktCount: bufferedPacketCount, maxPktSize: maxPacketSize)
        self.sandboxPacketBuffer = PacketBuffer(maxPktCount: 1, maxPktSize: maxPacketSize)
    }

    public func start() throws {
        guard self.readSource == nil, !stopped else {
            throw ContainerizationError(.invalidState, message: "bridge was already started")
        }

        // TODO: despite Swift's claim that there are no function calls inside the event handlers that could throw exceptions,
        // this is unfortunately simply not true. this is possibly connected due to some Objective-C legacy behavior
        // of the vmnet_interface API.
        // further investigation in catching these exceptions and making them visible might prove useful, since
        // otherwise the network service can silently crash without any trace in the logs. the sandbox service will
        // also keep running and will only notice that its interface has lost its carrier (quite fitting). only the
        // console logging does provide then a crash dump including stack trace featuring some message like this:
        //
        // *** Terminating app due to uncaught exception 'NSFileHandleOperationException', reason: '*** -[NSConcreteFileHandle fileDescriptor]: Bad file descriptor'

        // host -> vm: vmnet fires an event when packets are buffered.
        let st = vmnet_interface_set_event_callback(
            interfaceRef, .VMNET_INTERFACE_PACKETS_AVAILABLE, queue
        ) { [weak self] _, _ in
            self?.relayFromHostToSandbox()
        }
        guard st == .VMNET_SUCCESS else {
            throw ContainerizationError(.internalError, message: "vmnet_interface_set_event_callback failed")
        }

        // vm -> host: dispatch source on the socket.
        let src = DispatchSource.makeReadSource(fileDescriptor: networkEndpoint.fileDescriptor, queue: queue)
        src.setEventHandler { [weak self] in self?.relayFromSandboxToHost() }
        src.resume()
        self.readSource = src
    }

    public func stop() throws {
        guard !stopped else {
            throw ContainerizationError(.invalidState, message: "bridge was already stopped")
        }
        stopped = true

        guard let readSource else {
            throw ContainerizationError(.internalError, message: "read source for network endpoint has not been created")
        }
        readSource.cancel()

        let sema = DispatchSemaphore(value: 0)
        let st = vmnet_stop_interface(interfaceRef, queue, { _ in sema.signal() })
        sema.wait()

        guard st == .VMNET_SUCCESS else {
            throw ContainerizationError(.internalError, message: "failed to stop vmnet bridge interface")
        }
    }

    // bridge input and output helpers
    private func readFromHost() -> Int32 {
        hostPacketBuffer.reset()
        var count = Int32(hostPacketBuffer.maxPktCount)
        let st = vmnet_read(interfaceRef, hostPacketBuffer.packets, &count)
        guard st == .VMNET_SUCCESS, count > 0 else {
            return -1
        }
        return count
    }

    private func writeToSandbox(count: Int) -> Int {
        var written = 0
        for i in 0..<count {
            let pktSize = hostPacketBuffer.packets[i].vm_pkt_size
            guard write(networkEndpoint.fileDescriptor, hostPacketBuffer.iovs[i].iov_base, pktSize) == pktSize else {
                continue
            }
            written += 1
        }
        return written
    }

    // event handlers
    private func relayFromHostToSandbox() {
        let pktsIn = Int(readFromHost())
        guard pktsIn > 0 else {
            log.warning("received invalid number of packets from host: \(pktsIn)")
            return
        }
        let pktsOut = writeToSandbox(count: pktsIn)
        guard pktsOut == pktsIn else {
            log.warning("could not forward all packets to sandbox: \(pktsIn) != \(pktsOut)")
            return
        }
    }

    private func relayFromSandboxToHost() {
        // vmnet-helper uses Apple-private system calls sendmsg_x/recmsg_x to forward multiple packets
        // in a single system call on the bridge... that sounds intuitively as it will likely achieve quite a
        // performance improvement, but it also might break without further notice
        //
        // in doubt: this is just a fallback for the likely even more optimized internal VirtualizationFramework
        // bridging functionality
        let pktSize = read(
            networkEndpoint.fileDescriptor, sandboxPacketBuffer.buffers,
            sandboxPacketBuffer.maxPacketSize)
        guard pktSize > 0 else {
            log.warning("failed to read from sandbox socket: \(pktSize) - EOF?")
            return
        }

        sandboxPacketBuffer.iovs.pointee.iov_len = pktSize
        sandboxPacketBuffer.packets.pointee.vm_pkt_size = pktSize
        sandboxPacketBuffer.packets.pointee.vm_flags = 0

        var pktCount: Int32 = 1
        guard vmnet_write(interfaceRef, sandboxPacketBuffer.packets, &pktCount) == .VMNET_SUCCESS, pktCount == 1 else {
            log.warning("failed to forward packet from sandbox to host")
            return
        }
    }

}

public actor BridgeNetworkService: NetworkService {

    private let network: any Network
    private let variant: NetworkVariant
    private let log: Logger
    private var allocationsBySession: [XPCServerSession: [(hostname: String, bridge: Bridge?)]]
    private var macAddresses: [String: MACAddress]

    /// Set up a network service for the specified network.
    public init(
        network: any Network,
        variant: NetworkVariant,
        log: Logger
    ) async throws {
        guard await network.status != nil else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }

        self.network = network
        self.variant = variant
        self.log = log
        self.allocationsBySession = [:]
        self.macAddresses = [:]
    }

    @Sendable
    public func status() async throws -> NetworkStatus {
        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) is not running")
        }
        return status
    }

    @Sendable
    public func allocate(
        hostname: String,
        macAddress: MACAddress?,
        session: XPCServerSession
    ) async throws -> (attachment: Attachment, additionalData: XPCMessage?) {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard await network.status != nil else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }

        // retrieve configuration from the network
        // this is a bit awkward compared to the regular purpose of the network in managing allocations, since this is all
        // handled externally by the network infrastructure on the other side of the bridge. therefore the network is for us
        // simply a quite overblown struct/adapter that passes information along that are still unknown during creation time.
        var additionalData: XPCMessage?
        try network.withAdditionalData {
            additionalData = $0
        }

        guard let bridgeDictionary = additionalData?.xpcDictionary(key: NetworkKeys.additionalData.rawValue) else {
            throw ContainerizationError(.internalError, message: "did not receive bridge dictionary in network additional message")
        }
        let bridgeMessage = XPCMessage(object: bridgeDictionary)

        guard let hostInterface = bridgeMessage.string(key: BridgeNetworkKeys.hostInterface.rawValue)
        else {
            throw ContainerizationError(.invalidState, message: "bridge network is not assigned to a host interface")
        }

        var attachment: Attachment
        var bridge: Bridge?
        if variant == .bridged {
            let macAddress = macAddress ?? MACAddress((UInt64.random(in: 0...UInt64.max) & 0x0cff_ffff_ffff) | 0xf200_0000_0000)
            attachment = Attachment(
                network: network.id,
                hostname: hostname,
                ipv4Address: nil,
                ipv4Gateway: nil,
                ipv6Address: nil,
                macAddress: macAddress,
                mtu: nil,
            )
            bridge = nil
        } else {
            let enableTso =
                bridgeMessage.dataNoCopy(key: BridgeNetworkKeys.enableTso.rawValue) != nil ? bridgeMessage.bool(key: BridgeNetworkKeys.enableTso.rawValue) : nil
            let enableChecksumOffload =
                bridgeMessage.dataNoCopy(key: BridgeNetworkKeys.enableChecksumOffload.rawValue) != nil
                ? bridgeMessage.bool(key: BridgeNetworkKeys.enableChecksumOffload.rawValue) : nil
            let batchSize =
                bridgeMessage.dataNoCopy(key: BridgeNetworkKeys.bufferedPacketCount.rawValue) != nil
                ? Int(bridgeMessage.uint64(key: BridgeNetworkKeys.bufferedPacketCount.rawValue)) : nil

            bridge = try! Bridge(
                identifier: "vmnet-bridge-\(network.id)-\(hostname)", hostInterface: hostInterface, logger: log, enableTso: enableTso ?? false,
                enableChecksumOffload: enableChecksumOffload ?? false, bufferedPacketCount: batchSize ?? 64)
            try bridge!.start()

            attachment = Attachment(
                network: network.id,
                hostname: hostname,
                ipv4Address: nil,
                ipv4Gateway: nil,
                ipv6Address: nil,
                macAddress: bridge!.macAddress,
                mtu: bridge!.mtu
            )

            // add the sandbox-side fd endpoint to the bridge message
            bridgeMessage.set(key: BridgeNetworkKeys.sandboxEndpoint.rawValue, value: bridge!.sandboxEndpoint)

            // close the sandbox endpoint's fd, since we do not need it anymore and it has been just dup-ed
            // when we attached it to the XPC message above
            try bridge!.sandboxEndpoint.close()
        }

        log.info(
            "allocated attachment",
            metadata: [
                "hostname": "\(hostname)",
                "hostInterface": "\(hostInterface)",
                "macAddress": "\(attachment.macAddress!)",
                "bridge": "\(bridge?.identifier ?? "vf-based")",
            ])

        if allocationsBySession[session] == nil {
            allocationsBySession[session] = []
            await session.onDisconnect { [weak self] in
                await self?.releaseSession(session)
            }
        }
        allocationsBySession[session]!.append((hostname: hostname, bridge: bridge))
        macAddresses[hostname] = attachment.macAddress

        return (attachment: attachment, additionalData: additionalData)
    }

    private func releaseSession(_ session: XPCServerSession) async {
        guard let allocations = allocationsBySession.removeValue(forKey: session) else {
            return
        }
        for allocation: (hostname: String, bridge: Bridge?) in allocations {
            macAddresses[allocation.hostname] = nil
            guard let bridge = allocation.bridge else {
                continue
            }
            do {
                try bridge.stop()
            } catch let error as ContainerizationError {
                log.error(
                    "failed to stop bridge for attachment",
                    metadata: [
                        "error": Logger.MetadataValue.string(error.message)
                    ])
            } catch {
                assert(false, "should never happen")
            }
        }
        log.info("released session", metadata: ["allocations": "\(allocations.count)"])
    }

    @Sendable
    public func lookup(hostname: String) async throws -> Attachment? {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard await network.status != nil else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }
        guard let macAddress = macAddresses[hostname] else {
            log.warning("MAC address for hostname \(hostname) is not a valid attachment")
            return nil
        }

        let attachment = Attachment(
            network: network.id,
            hostname: hostname,
            ipv4Address: nil,
            ipv4Gateway: nil,
            ipv6Address: nil,
            macAddress: macAddress
        )
        log.info(
            "lookup attachment",
            metadata: [
                "hostname": "\(hostname)",
                "macAddress": "\(macAddress)",
            ])

        return attachment
    }
}
