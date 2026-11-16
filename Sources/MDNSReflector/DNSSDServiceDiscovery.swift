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

import ContainerizationExtras
import Foundation
import Logging
import dnssd

/// An error reported by the DNS-SD API.
struct DNSSDError: Error, CustomStringConvertible {
    let operation: String
    let code: DNSServiceErrorType

    var description: String {
        "\(operation) failed with DNS-SD error \(code)"
    }
}

/// Service discovery backed by the host's mDNS responder, through the DNS-SD API.
///
/// The object and the operations it returns must be used from `queue`, which
/// is also the queue that the handlers are called on.
final class DNSSDServiceDiscovery: ServiceDiscovery {
    private static let domain = "local."
    private static let serviceTypeEnumeration = "_services._dns-sd._udp"

    private let queue: DispatchQueue
    private let log: Logger

    init(queue: DispatchQueue, log: Logger) {
        self.queue = queue
        self.log = log
    }

    func browseServiceTypes(
        interfaceIndex: UInt32,
        handler: @escaping (BrowseEvent<String>) -> Void
    ) throws -> any DiscoveryOperation {
        let context = BrowseContext(failure: failureLogger("browse service types")) { added, serviceName, regtype in
            // The enumeration query reports a type in two parts, such as
            // "_hap" and "_tcp.local.".
            guard let transport = regtype.split(separator: ".").first else {
                return
            }
            let type = "\(serviceName).\(transport)"
            handler(added ? .added(type) : .removed(type))
        }
        return try start("browse service types", context: context) { ref, pointer in
            DNSServiceBrowse(&ref, 0, interfaceIndex, Self.serviceTypeEnumeration, Self.domain, browseReply, pointer)
        }
    }

    func browse(
        type: ServiceType,
        interfaceIndex: UInt32,
        handler: @escaping (BrowseEvent<String>) -> Void
    ) throws -> any DiscoveryOperation {
        let operation = "browse \(type)"
        let context = BrowseContext(failure: failureLogger(operation)) { added, serviceName, _ in
            handler(added ? .added(serviceName) : .removed(serviceName))
        }
        return try start(operation, context: context) { ref, pointer in
            DNSServiceBrowse(&ref, 0, interfaceIndex, type.description, Self.domain, browseReply, pointer)
        }
    }

    func resolve(
        _ instance: ServiceInstance,
        interfaceIndex: UInt32,
        handler: @escaping (ResolvedService) -> Void
    ) throws -> any DiscoveryOperation {
        let operation = "resolve \(instance)"
        let context = ResolveContext(failure: failureLogger(operation), handler: handler)
        return try start(operation, context: context) { ref, pointer in
            DNSServiceResolve(&ref, 0, interfaceIndex, instance.name, instance.type.description, Self.domain, resolveReply, pointer)
        }
    }

    func lookupIPv4Addresses(
        host: String,
        interfaceIndex: UInt32,
        handler: @escaping ([IPv4Address]) -> Void
    ) throws -> any DiscoveryOperation {
        let operation = "look up \(host)"
        let context = AddressContext(failure: failureLogger(operation), handler: handler)
        return try start(operation, context: context) { ref, pointer in
            DNSServiceGetAddrInfo(&ref, 0, interfaceIndex, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host, addressReply, pointer)
        }
    }

    func register(
        _ instance: ServiceInstance,
        interfaceIndex: UInt32,
        port: UInt16,
        txt: [UInt8],
        handler: @escaping (RegistrationEvent) -> Void
    ) throws -> any ServiceRegistration {
        let operation = "register \(instance)"
        guard let txtLength = UInt16(exactly: txt.count) else {
            throw DNSSDError(operation: operation, code: DNSServiceErrorType(kDNSServiceErr_BadParam))
        }
        let context = RegisterContext(handler: handler)
        return try start(operation, context: context) { ref, pointer in
            // A nil host registers the service as provided by this host, so
            // that it resolves to the addresses of the chosen interface.
            DNSServiceRegister(
                &ref, 0, interfaceIndex, instance.name, instance.type.description, Self.domain, nil,
                port.bigEndian, txtLength, txt, registerReply, pointer)
        }
    }

    private func failureLogger(_ operation: String) -> (DNSServiceErrorType) -> Void {
        let log = self.log
        return { code in
            log.warning("mDNS operation failed", metadata: ["operation": "\(operation)", "code": "\(code)"])
        }
    }

    private func start(
        _ operation: String,
        context: AnyObject,
        _ body: (inout DNSServiceRef?, UnsafeMutableRawPointer) -> DNSServiceErrorType
    ) throws -> DNSSDOperation {
        var ref: DNSServiceRef?
        let code = body(&ref, Unmanaged.passUnretained(context).toOpaque())
        guard code == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            throw DNSSDError(operation: operation, code: code)
        }
        return try DNSSDOperation(ref: ref, context: context, queue: queue, operation: operation)
    }
}

/// A DNS-SD operation, and the context that its C callback uses.
///
/// The callback receives an unretained pointer to the context, which this
/// object keeps alive until the operation is cancelled. Cancelling on the
/// callback queue guarantees that no callback is running or still to come.
private final class DNSSDOperation: ServiceRegistration {
    private let operation: String
    private var ref: DNSServiceRef?
    private var context: AnyObject?

    init(ref: DNSServiceRef, context: AnyObject, queue: DispatchQueue, operation: String) throws {
        self.operation = operation
        let code = DNSServiceSetDispatchQueue(ref, queue)
        guard code == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            DNSServiceRefDeallocate(ref)
            throw DNSSDError(operation: operation, code: code)
        }
        self.ref = ref
        self.context = context
    }

    deinit {
        cancel()
    }

    func cancel() {
        guard let ref else {
            return
        }
        DNSServiceRefDeallocate(ref)
        self.ref = nil
        self.context = nil
    }

    func updateTXT(_ txt: [UInt8]) throws {
        guard let ref else {
            return
        }
        // An empty TXT record is a single zero-length string.
        let data = txt.isEmpty ? [0] : txt
        guard let length = UInt16(exactly: data.count) else {
            throw DNSSDError(operation: "update \(operation)", code: DNSServiceErrorType(kDNSServiceErr_BadParam))
        }
        let code = DNSServiceUpdateRecord(ref, nil, 0, length, data, 0)
        guard code == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            throw DNSSDError(operation: "update \(operation)", code: code)
        }
    }
}

private final class BrowseContext {
    let failure: (DNSServiceErrorType) -> Void
    let handler: (_ added: Bool, _ serviceName: String, _ regtype: String) -> Void

    init(failure: @escaping (DNSServiceErrorType) -> Void, handler: @escaping (Bool, String, String) -> Void) {
        self.failure = failure
        self.handler = handler
    }
}

private final class ResolveContext {
    let failure: (DNSServiceErrorType) -> Void
    let handler: (ResolvedService) -> Void

    init(failure: @escaping (DNSServiceErrorType) -> Void, handler: @escaping (ResolvedService) -> Void) {
        self.failure = failure
        self.handler = handler
    }
}

private final class AddressContext {
    let failure: (DNSServiceErrorType) -> Void
    let handler: ([IPv4Address]) -> Void
    var pending: [IPv4Address] = []

    init(failure: @escaping (DNSServiceErrorType) -> Void, handler: @escaping ([IPv4Address]) -> Void) {
        self.failure = failure
        self.handler = handler
    }
}

private final class RegisterContext {
    let handler: (RegistrationEvent) -> Void

    init(handler: @escaping (RegistrationEvent) -> Void) {
        self.handler = handler
    }
}

// A handler may cancel its own operation, which releases the context, so each
// callback keeps the context alive until the handler returns.

private func browseReply(
    _ ref: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ serviceName: UnsafePointer<CChar>?,
    _ regtype: UnsafePointer<CChar>?,
    _ replyDomain: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else {
        return
    }
    let box = Unmanaged<BrowseContext>.fromOpaque(context).takeUnretainedValue()
    withExtendedLifetime(box) {
        guard errorCode == DNSServiceErrorType(kDNSServiceErr_NoError), let serviceName, let regtype else {
            box.failure(errorCode)
            return
        }
        let added = flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0
        box.handler(added, String(cString: serviceName), String(cString: regtype))
    }
}

private func resolveReply(
    _ ref: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ fullname: UnsafePointer<CChar>?,
    _ hostTarget: UnsafePointer<CChar>?,
    _ port: UInt16,
    _ txtLength: UInt16,
    _ txtRecord: UnsafePointer<UInt8>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else {
        return
    }
    let box = Unmanaged<ResolveContext>.fromOpaque(context).takeUnretainedValue()
    withExtendedLifetime(box) {
        guard errorCode == DNSServiceErrorType(kDNSServiceErr_NoError), let hostTarget else {
            box.failure(errorCode)
            return
        }
        let txt = txtRecord.map { Array(UnsafeBufferPointer(start: $0, count: Int(txtLength))) } ?? []
        box.handler(ResolvedService(host: String(cString: hostTarget), port: UInt16(bigEndian: port), txt: txt))
    }
}

private func addressReply(
    _ ref: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ hostname: UnsafePointer<CChar>?,
    _ address: UnsafePointer<sockaddr>?,
    _ ttl: UInt32,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else {
        return
    }
    let box = Unmanaged<AddressContext>.fromOpaque(context).takeUnretainedValue()
    withExtendedLifetime(box) {
        if errorCode == DNSServiceErrorType(kDNSServiceErr_NoError) {
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let address, Int32(address.pointee.sa_family) == AF_INET {
                let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
                }
                if let ipv4 = try? IPv4Address(bytes) {
                    box.pending.append(ipv4)
                }
            }
        } else if errorCode != DNSServiceErrorType(kDNSServiceErr_NoSuchRecord) {
            // A name without an address is an answer, not a failure.
            box.failure(errorCode)
        }

        guard flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 else {
            return
        }
        let answers = box.pending
        box.pending = []
        box.handler(answers)
    }
}

private func registerReply(
    _ ref: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ errorCode: DNSServiceErrorType,
    _ name: UnsafePointer<CChar>?,
    _ regtype: UnsafePointer<CChar>?,
    _ domain: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else {
        return
    }
    let box = Unmanaged<RegisterContext>.fromOpaque(context).takeUnretainedValue()
    withExtendedLifetime(box) {
        guard errorCode == DNSServiceErrorType(kDNSServiceErr_NoError), let name else {
            box.handler(.failed(code: errorCode))
            return
        }
        box.handler(.registered(name: String(cString: name)))
    }
}
