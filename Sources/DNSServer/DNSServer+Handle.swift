//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import Foundation
import NIOCore
import NIOPosix

extension DNSServer {
    /// Handles the DNS request.
    /// - Parameters:
    ///   - outbound: The NIOAsyncChannelOutboundWriter for which to respond.
    ///   - packet: The request packet.
    func handle(
        outbound: NIOAsyncChannelOutboundWriter<AddressedEnvelope<ByteBuffer>>,
        packet: inout AddressedEnvelope<ByteBuffer>
    ) async throws {
        // RFC 1035 §2.3.4 limits UDP DNS messages to 512 bytes. We don't implement
        // EDNS0 (RFC 6891), and this server only resolves host A/AAAA queries, so a
        // legitimate query will never approach this limit. Reject oversized packets
        // before reading to avoid allocating memory for malformed or malicious datagrams.
        let maxPacketSize = 512
        guard packet.data.readableBytes <= maxPacketSize else {
            self.log?.error("dropping oversized DNS packet: \(packet.data.readableBytes) bytes")
            return
        }

        var data = Data()
        self.log?.debug("reading data")
        while packet.data.readableBytes > 0 {
            if let chunk = packet.data.readBytes(length: packet.data.readableBytes) {
                data.append(contentsOf: chunk)
            }
        }

        self.log?.debug("deserializing message")

        // always send response
        let responseData: Data
        do {
            let query = try Message(deserialize: data)
            self.log?.debug("processing query: \(query.questions)")

            self.log?.debug("awaiting processing")
            var response =
                try await handler.answer(query: query)
                ?? Message(
                    id: query.id,
                    type: .response,
                    returnCode: .notImplemented,
                    questions: query.questions,
                    answers: []
                )

            // Only set NXDOMAIN if handler didn't explicitly set noError (NODATA response).
            // This preserves NODATA responses for AAAA queries when A record exists,
            // which prevents musl libc from treating empty AAAA as "domain doesn't exist".
            if response.answers.isEmpty && response.returnCode != .noError {
                response.returnCode = .nonExistentDomain
            }

            self.log?.debug("serializing response")
            responseData = try response.serialize()
        } catch let error as DNSBindError {
            // Best-effort: echo the transaction ID from the first two bytes of the raw packet.
            let rawId = data.count >= 2 ? data[0..<2].withUnsafeBytes { $0.load(as: UInt16.self) } : 0
            let id = UInt16(bigEndian: rawId)
            let returnCode: ReturnCode
            switch error {
            case .unsupportedValue:
                self.log?.error("not implemented processing DNS message: \(error)")
                returnCode = .notImplemented
            default:
                self.log?.error("format error processing DNS message: \(error)")
                returnCode = .formatError
            }
            let response = Message(
                id: id,
                type: .response,
                returnCode: returnCode,
                questions: [],
                answers: []
            )
            responseData = try response.serialize()
        } catch {
            let rawId = data.count >= 2 ? data[0..<2].withUnsafeBytes { $0.load(as: UInt16.self) } : 0
            let id = UInt16(bigEndian: rawId)
            self.log?.error("error processing DNS message: \(error)")
            let response = Message(
                id: id,
                type: .response,
                returnCode: .serverFailure,
                questions: [],
                answers: []
            )
            responseData = try response.serialize()
        }

        self.log?.debug("sending response")
        let rData = ByteBuffer(bytes: responseData)
        do {
            try await outbound.write(AddressedEnvelope(remoteAddress: packet.remoteAddress, data: rData))
        } catch {
            self.log?.error("failed to send DNS response: \(error)")
        }

        self.log?.debug("processing done")

    }
}
