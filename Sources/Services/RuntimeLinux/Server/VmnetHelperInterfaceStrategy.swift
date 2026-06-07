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

import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationExtras
import CryptoKit
import Foundation
import Logging

/// Creates network interfaces for bridged networks by launching a
/// vmnet-helper process per interface.
///
/// vmnet-helper (https://github.com/nirs/vmnet-helper) attaches to the
/// physical host interface in vmnet bridged mode and relays Ethernet
/// frames over a `SOCK_DGRAM` socketpair. The strategy spawns the helper,
/// reads the interface parameters it reports on stdout, and hands the VM
/// end of the socketpair to the virtual machine. The MAC address comes
/// from vmnet, not from the caller.
public struct VmnetHelperInterfaceStrategy: InterfaceStrategy {
    /// Default helper locations for Homebrew on macOS 26 and newer,
    /// then the install script location for macOS 15 and earlier.
    private static let defaultHelperPaths = [
        "/opt/homebrew/opt/vmnet-helper/libexec/vmnet-helper",
        "/usr/local/opt/vmnet-helper/libexec/vmnet-helper",
        "/opt/vmnet-helper/bin/vmnet-helper",
    ]

    private static let startupTimeout = Duration.seconds(15)
    // The Virtualization framework requires SO_RCVBUF of at least twice
    // SO_SNDBUF on the attachment socket and recommends four times.
    private static let socketSendBufferSize: Int32 = 1024 * 1024
    private static let socketReceiveBufferSize: Int32 = 4 * 1024 * 1024

    private let log: Logger

    public init(log: Logger) {
        self.log = log
    }

    public func toInterface(attachment: Attachment, interfaceIndex: Int, additionalData: XPCMessage?) async throws -> Interface {
        guard let additionalData else {
            throw ContainerizationError(.invalidState, message: "bridged network attachment has no additional data")
        }
        guard let hostInterface = additionalData.string(key: VmnetHelperNetwork.AdditionalDataKey.interface.rawValue) else {
            throw ContainerizationError(.invalidState, message: "bridged network attachment does not specify a host interface")
        }
        let helperPath = try Self.resolveHelperPath(
            override: additionalData.string(key: VmnetHelperNetwork.AdditionalDataKey.helperPath.rawValue)
        )

        // A stable interface ID gives the attachment a stable vmnet MAC
        // address across container restarts.
        let interfaceId = Self.stableInterfaceId(network: attachment.network, hostname: attachment.hostname, interfaceIndex: interfaceIndex)

        // The helper gets one end of the socketpair as its stdin and
        // the VM gets the other.
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw ContainerizationError(.internalError, message: "socketpair failed with errno \(errno)")
        }
        let vmFd = fds[0]
        let helperFd = fds[1]
        for fd in fds {
            var sendSize = Self.socketSendBufferSize
            var receiveSize = Self.socketReceiveBufferSize
            // A restrictive kern.ipc.maxsockbuf makes the kernel reject these
            // sizes rather than clamp them, leaving the socket on its smaller
            // default buffer. That is not fatal, but it can cause packet drops
            // under load, so surface it instead of discarding the result.
            if setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendSize, socklen_t(MemoryLayout<Int32>.size)) != 0 {
                log.warning(
                    "failed to set vmnet-helper socket send buffer size; check kern.ipc.maxsockbuf",
                    metadata: ["size": "\(sendSize)", "errno": "\(errno)"]
                )
            }
            if setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveSize, socklen_t(MemoryLayout<Int32>.size)) != 0 {
                log.warning(
                    "failed to set vmnet-helper socket receive buffer size; check kern.ipc.maxsockbuf",
                    metadata: ["size": "\(receiveSize)", "errno": "\(errno)"]
                )
            }
        }

        let stdoutPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = [
            "--fd", "0",
            "--operation-mode", "bridged",
            "--shared-interface", hostInterface,
            "--interface-id", interfaceId,
        ]
        process.standardInput = FileHandle(fileDescriptor: helperFd, closeOnDealloc: false)
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        log.info(
            "starting vmnet-helper",
            metadata: [
                "path": "\(helperPath)",
                "hostInterface": "\(hostInterface)",
                "interfaceId": "\(interfaceId)",
                "network": "\(attachment.network)",
            ])

        // The vm end is handed off to the returned interface on
        // success. Every failure path below reaps the helper and the fd.
        var handedOff = false
        var launched = false
        defer {
            if !handedOff {
                if launched {
                    // A no op when the process has already exited.
                    process.terminate()
                }
                close(vmFd)
            }
        }

        do {
            try process.run()
            launched = true
        } catch {
            close(helperFd)
            throw ContainerizationError(.internalError, message: "failed to start vmnet-helper at \(helperPath)", cause: error)
        }

        // The child holds its own copies of the helper end and the
        // pipe's write end. Close the parent's copies so peer close and
        // EOF detection work.
        close(helperFd)
        try? stdoutPipe.fileHandleForWriting.close()

        // The handshake read blocks for up to `startupTimeout`. Run it
        // on a GCD queue so it does not stall a concurrency pool thread
        // and with it the runtime's other XPC routes. A cancellation
        // handler terminates the helper so the blocking read unblocks on
        // teardown (the helper's pipe closes, the read sees EOF) instead
        // of waiting out the startup timeout.
        let readFd = stdoutPipe.fileHandleForReading.fileDescriptor
        let parameters: [String: Any] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    let result = Result { try Self.readInterfaceParameters(fd: readFd, process: process) }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            process.terminate()
        }

        guard let macString = parameters["vmnet_mac_address"] as? String,
            let macAddress = try? MACAddress(macString)
        else {
            throw ContainerizationError(.internalError, message: "vmnet-helper reported no valid MAC address")
        }
        let vmnetMtu = Self.reportedMtu(parameters["vmnet_mtu"]) ?? 1500
        // The guest link MTU honors the attachment option but cannot
        // exceed the frame size of the vmnet data path.
        let mtu = min(attachment.mtu ?? vmnetMtu, vmnetMtu)

        log.info(
            "started vmnet-helper",
            metadata: [
                "macAddress": "\(macAddress)",
                "mtu": "\(mtu)",
                "vmnetMtu": "\(vmnetMtu)",
                "network": "\(attachment.network)",
            ])

        // Only the first interface carries a gateway, so the guest installs a
        // single default route (and resolver) via it. Later interfaces reach
        // only their own subnet. Egress network must be listed first.
        let ipv4Gateway = interfaceIndex == 0 ? attachment.ipv4Gateway : nil
        let interface = VmnetHelperInterface(
            ipv4Address: attachment.ipv4Address,
            ipv4Gateway: ipv4Gateway,
            // The guest must use the MAC address vmnet assigned to the
            // helper's interface. Frames from any other source address
            // would not pass the bridge.
            macAddress: macAddress,
            mtu: mtu,
            vmnetMtu: vmnetMtu,
            fileHandle: FileHandle(fileDescriptor: vmFd, closeOnDealloc: true),
            helperProcess: process
        )
        handedOff = true
        return interface
    }

    /// The MTU as reported in the helper's parameter JSON. Tolerates a
    /// string-encoded number rather than silently substituting a default.
    private static func reportedMtu(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber {
            return number.uint32Value
        }
        if let string = value as? String {
            return UInt32(string)
        }
        return nil
    }

    private static func resolveHelperPath(override: String?) throws -> String {
        if let override {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw ContainerizationError(.notFound, message: "vmnet-helper not found at configured path \(override)")
            }
            return override
        }
        for path in Self.defaultHelperPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        throw ContainerizationError(
            .notFound,
            message: "vmnet-helper not found; install it with `brew install nirs/tap/vmnet-helper` or set the helper-path network option"
        )
    }

    /// Derive a stable UUID from the attachment identity so vmnet
    /// assigns the same MAC address on every container start. The first
    /// 16 digest bytes form the UUID. vmnet only parses the string, so
    /// RFC 4122 version bits are not needed.
    private static func stableInterfaceId(network: String, hostname: String, interfaceIndex: Int) -> String {
        let digest = SHA256.hash(data: Data("container-bridged:\(network):\(hostname):\(interfaceIndex)".utf8))
        return digest.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }.uuidString
    }

    /// Read the single-line JSON interface description that vmnet-helper
    /// prints to stdout once the vmnet interface starts.
    private static func readInterfaceParameters(fd: Int32, process: Process) throws -> [String: Any] {
        var buffer = Data()
        var scanned = 0
        let deadline = ContinuousClock.now + Self.startupTimeout

        func parse(_ line: Data) throws -> [String: Any] {
            guard let object = try? JSONSerialization.jsonObject(with: line),
                let parameters = object as? [String: Any]
            else {
                throw ContainerizationError(.internalError, message: "cannot parse vmnet-helper interface description")
            }
            return parameters
        }

        while true {
            // Only newly appended bytes need scanning for the terminator.
            if let newlineIndex = buffer[scanned...].firstIndex(of: UInt8(ascii: "\n")) {
                return try parse(buffer[..<newlineIndex])
            }
            scanned = buffer.count

            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else {
                throw ContainerizationError(.internalError, message: "timed out waiting for vmnet-helper to start")
            }

            var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            // Cap each wait at a short interval so the loop revisits its
            // deadline (and sees the helper's pipe close on teardown)
            // promptly rather than blocking for up to a full second.
            let timeoutMs = Int32(min(remaining / .milliseconds(1), 100))
            let rc = poll(&pollFd, 1, max(timeoutMs, 1))
            if rc < 0 {
                if errno == EINTR {
                    continue
                }
                throw ContainerizationError(.internalError, message: "poll on vmnet-helper output failed with errno \(errno)")
            }
            if rc == 0 {
                continue
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw ContainerizationError(.internalError, message: "read on vmnet-helper output failed with errno \(errno)")
            }
            if count == 0 {
                // EOF. A complete description may lack a trailing newline,
                // so try the buffered bytes before failing.
                if !buffer.isEmpty, let parameters = try? parse(buffer) {
                    return parameters
                }
                // The helper exited before reporting parameters, which
                // typically means a bad host interface or missing
                // privileges on macOS 15 and earlier.
                process.waitUntilExit()
                throw ContainerizationError(
                    .internalError,
                    message: "vmnet-helper exited with status \(process.terminationStatus) before reporting interface parameters"
                )
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
